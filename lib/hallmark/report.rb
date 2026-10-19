# typed: strict
# frozen_string_literal: true

module Hallmark
  # The outcome of one analysis run: a finding per exposure that has a
  # counterexample, the exposures with none within scope, those the solver
  # gave no verdict for (unknown: out of time or memory), and, when the
  # exposures came from stamps, the entry points that ran with no
  # authorization call (threat 10), the stamps the rule's code contradicts
  # (drift) and what the stamps did not cover.
  class Report
    # Not-observed combinations printed per rule; the rest are counted.
    COMBINATIONS_SHOWN = 8
    ROUTES_SHOWN = 12

    # An exposure the solver gave no verdict for, and why.
    Unknown = Struct.new(:exposure, :reason)

    attr_reader :analysis, :findings, :verified, :unknown, :unchecked, :drift, :coverage, :lints

    # Exit status for several reports: 1 on any counterexample, unchecked
    # entry point or drift, else 2 on any unknown, else 0.
    def self.exit_code(reports)
      codes = reports.map(&:exit_code)
      codes.include?(1) ? 1 : codes.max || 0
    end

    def initialize(analysis, receipt)
      @analysis = analysis
      @findings = []
      @verified = []
      @unknown = []
      inference = analysis.inference
      @unchecked = inference ? inference.unchecked : []
      @drift = inference ? inference.drift : []
      # DeclarativePolicy hazards (D3, D4) in the abilities read from code.
      @lints = inference&.extractor&.lints || []
      @coverage = inference&.coverage
      analysis.exposures.each { |exposure| read(exposure, receipt) }
    end

    # An unchecked entry point fails the run like a counterexample: it is a
    # request the app served with no authorization at all. So does drift,
    # since the guards checked may not be the app's, and so does a
    # DeclarativePolicy hazard (D3, D4), whose policy does not mean what it
    # reads as. An unknown is not a failure, but it is not clean either.
    def failed? = findings.any? || unchecked.any? || drift.any? || lints.any?
    def clean? = !failed? && unknown.empty?

    def exit_code
      return 1 if failed?

      unknown.empty? ? 0 : 2
    end

    def to_s
      scope = Hallmark.configuration.scope
      lines = ["Hallmark #{VERSION}, #{analysis.name}, Alloy #{ALLOY_VERSION}, scope #{scope}", ""]
      findings.each { |finding| lines.concat(finding_lines(finding)) }
      unchecked.each do |entry_point|
        lines << "FAIL  #{entry_point} finished without an authorization call (threat 10)"
      end
      lines.concat(unknown_lines)
      verified.each { |exposure| lines << Report.ok_line(exposure) }
      lines.concat(drift_lines)
      lints.each { |lint| lines << "FAIL  #{lint} (policy-DSL hazard)" }
      lines << ""
      lines << summary
      lines.concat(coverage_lines)
      lines.join("\n")
    end

    # One finding as `hallmark check` prints it; the RSpec matchers print the
    # same lines.
    def self.finding_lines(finding)
      exposure = finding.exposure
      lines = ["FAIL  #{exposure.action} (#{exposure.op} #{exposure.resource})", "      guard: #{exposure.guard}"]
      lines << "      #{exposure.basis}" if exposure.basis
      lines << "      #{finding.message}"
      lines << "      intended pattern: #{finding.pattern}"
      lines << "      #{finding.hint}" if finding.hint
      lines
    end

    def self.unknown_line(exposure, reason)
      "??    #{exposure.action} (#{exposure.op} #{exposure.resource}): unknown, #{reason}"
    end

    def self.ok_line(exposure) = "ok    #{exposure.action} (#{exposure.op} #{exposure.resource})"

    def finding_lines(finding) = Report.finding_lines(finding)

    def summary
      total = findings.size + verified.size + unknown.size
      problems = problems(total)
      return "#{problems.join(", ")}." if problems.any?

      "No counterexamples in #{total} checks (bounded: scope #{Hallmark.configuration.scope})."
    end

    def problems(total)
      out = [verdicts(total)].compact
      out << count(unchecked.size, "unchecked entry point") if unchecked.any?
      out << "#{count(drift.size, "drifting decision")} (stamps the rule's code contradicts)" if drift.any?
      out << count(lints.size, "policy-DSL hazard") if lints.any?
      out << unknown_summary(total) if unknown.any?
      out
    end

    # The checks' outcome beside other problems; never "no counterexample"
    # next to an unknown, which is not one.
    def verdicts(total)
      return "#{count(findings.size, "counterexample")} in #{count(total, "check")}" if findings.any?
      return nil unless unknown.empty? && (unchecked.any? || drift.any? || lints.any?)

      "No counterexamples in #{count(total, "check")}"
    end

    # The drift section: each stamped decision the rule's extracted guard
    # contradicts, with the rule's source line and the stamp's facts.
    def drift_lines
      return [] if drift.empty?

      lines = ["", "Drift (stamped decisions the rule's code contradicts; the extractor or a `term` is wrong):"]
      drift.each { |item| lines.concat(Report.drift_lines(item)) }
      lines
    end

    def self.drift_lines(item)
      raised = " (raised #{item.raised.join(", ")})" if item.raised.any?
      claim = if item.allow?
                "allowed, but its code allows only where #{item.bound} (upper bound), false here"
              else
                "denied#{raised}, but its code allows wherever #{item.bound} (lower bound), true here"
              end
      ["DRIFT #{item.rule} (#{item.resource}) at #{item.location}: #{claim}",
       "      facts: #{item.facts}",
       "      stamped at: #{item.seen.join(", ")}"]
    end

    def unknown_lines = unknown.map { |item| Report.unknown_line(item.exposure, item.reason) }

    def unknown_summary(total)
      checks = " in #{count(total, "check")}" if findings.empty?
      "#{unknown.size} unknown#{checks} (no verdict; raise HALLMARK_TIMEOUT or lower the scope)"
    end

    def count(number, noun) = "#{number} #{noun}#{"s" unless number == 1}"

    # The coverage section: what the stamps leave open. Never findings.
    def coverage_lines
      coverage = @coverage
      return [] if coverage.nil? || coverage.empty?

      lines = ["", "Not observed (coverage gaps, not findings):"]
      coverage.gaps.each do |gap|
        lines << "  #{gap.rule} (#{gap.op} #{gap.resource}; #{count(gap.allows, "allow-stamp")}, " \
                 "#{count(gap.denies, "deny-stamp")}), never stamped with:"
        gap.combinations.first(COMBINATIONS_SHOWN).each { |combination| lines << "    #{combination}" }
        hidden = gap.combinations.size - COMBINATIONS_SHOWN
        lines << "    and #{hidden} more" if hidden.positive?
      end
      lines.concat(opaque_lines(coverage))
      coverage_lists(coverage).each do |title, names|
        lines << "  #{title}: #{names.join(", ")}" if names.any?
      end
      lines.concat(route_lines(coverage))
    end

    # Calls inside rules the extractor could not read (docs/adr/0003).
    def opaque_lines(coverage)
      return [] if coverage.opaque.empty?

      ["  Calls in rules and controller checks that Hallmark could not read (the checked guard assumes each one " \
       "denies):",
       *coverage.opaque.map { |entry| "    #{entry}" }]
    end

    # The coverage lists printed after the per-rule gaps, by title.
    def coverage_lists(coverage)
      {
        "Rules with no observed allow" => coverage.never_allowed,
        "Rules no entry point enforced (seen only in queries or outside requests)" => coverage.unreached,
        "Rules read from code that no test called (no entry point known)" => coverage.code_only,
        "Rules checked against a class or a name, not a record (not modeled)" => coverage.class_level,
        "Rules with no op (declare `rule POLICY, NAME, op:` in the map block)" => coverage.without_op,
        "Unmapped resources" => coverage.unmapped,
        "Entry points that redirected a GET without an authorization call (authorized in other requests)" =>
          coverage.redirected,
        "Entry points that served a request without an authorization call, exempt from verify_authorized " \
        "in the controller" => coverage.exempt,
        "Entry points not checked: their controller's own check depends on calls Hallmark could not read" =>
          coverage.checks_unread
      }
    end

    # Routes no test reached, which can be many in a whole app: each list
    # shows its first ROUTES_SHOWN names and counts the rest.
    def route_lists(coverage)
      {
        "Routes no test reached whose code authorizes a record Hallmark could not resolve to a rule" =>
          coverage.routes_unresolved,
        "Routes no test reached with no authorization call in the code Hallmark reads" =>
          coverage.routes_unchecked,
        "Routes no test reached in controllers outside app/controllers" => coverage.routes_unread
      }
    end

    private

    def route_lines(coverage)
      route_lists(coverage).filter_map do |title, names|
        next if names.empty?

        hidden = names.size - ROUTES_SHOWN
        more = hidden.positive? ? " and #{hidden} more" : ""
        "  #{title} (#{names.size}): #{names.first(ROUTES_SHOWN).join(", ")}#{more}"
      end
    end

    # Files one exposure's verdict.
    def read(exposure, receipt)
      command = receipt[exposure.check_name]
      raise SolverError, "Alloy returned no result for #{exposure.action}" unless command

      instance = command.instance
      if (reason = command.reason)
        @unknown << Unknown.new(exposure, reason)
      elsif instance
        @findings << Finding.from(exposure, instance, analysis.mapping)
      else
        @verified << exposure
      end
    end
  end
end
