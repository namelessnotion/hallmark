# typed: strict
# frozen_string_literal: true

module Hallmark
  # The outcome of one analysis run: a finding per exposure that has a
  # counterexample, the exposures with none within scope, those the solver
  # gave no verdict for (unknown: out of time or memory), and, when the
  # exposures came from stamps, the entry points that ran with no
  # authorization call (threat 10), the stamps the rule's code contradicts
  # (drift), the allows after a revocation that nothing else explains
  # (stale access, threat 9) and what the stamps did not cover.
  class Report
    # Not-observed combinations printed per rule; the rest are counted.
    COMBINATIONS_SHOWN = 8
    ROUTES_SHOWN = 12

    # An exposure the solver gave no verdict for, and why.
    Unknown = Struct.new(:exposure, :reason)

    attr_reader :analysis, :findings, :verified, :unknown, :unchecked, :drift, :stale_access, :coverage, :lints

    # Exit status for several reports: 1 on any counterexample, unchecked
    # entry point, drift, stale access or lint, else 2 on any unknown, else 0.
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
      @stale_access = inference ? inference.stale_access : []
      @lints = Report.lints_of(analysis)
      @coverage = inference&.coverage
      analysis.exposures.each { |exposure| read(exposure, receipt) }
    end

    # An unchecked entry point fails the run like a counterexample: it is a
    # request the app served with no authorization at all. So does drift,
    # since the guards checked may not be the app's, and so does a
    # DeclarativePolicy hazard (D3, D4), whose policy does not mean what it
    # reads as, and stale access and a revocation hazard (R1), an allow that
    # outlived the role behind it. An unknown is not a failure, but it is not
    # clean either.
    # The extractor the analysis's guards were read with, if any; SARIF
    # finds an unchecked entry point's action through it.
    def extractor = analysis.inference&.extractor

    def failed? = findings.any? || unchecked.any? || drift.any? || stale_access.any? || lints.any?
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
      lines.concat(stale_access_lines)
      lints.each { |lint| lines << "FAIL  #{lint} (#{Report.hazard(lint)})" }
      lines << ""
      lines << summary
      lines.concat(trailer_lines).join("\n")
    end

    # One finding as `hallmark check` prints it; the RSpec matchers print the
    # same lines.
    def self.finding_lines(finding)
      exposure = finding.exposure
      lines = ["FAIL  #{exposure.action} (#{Report.doing(exposure)})", "      guard: #{exposure.guard}"]
      lines << "      #{exposure.basis}" if exposure.basis
      lines << "      #{finding.message}"
      lines << "      path: #{finding.path}" if finding.path
      lines << "      intended pattern: #{finding.pattern}"
      intended = finding.intended
      lines << "      intended: #{intended}" if intended
      lines << "      #{finding.hint}" if finding.hint
      lines
    end

    def self.unknown_line(exposure, reason)
      "??    #{exposure.action} (#{exposure.doing}): unknown, #{reason}"
    end

    def self.ok_line(exposure) = "ok    #{exposure.action} (#{exposure.doing})"

    # What a failing exposure does, and the serializer field that shows it
    # when it was read from one (phase 3 step 8).
    def self.doing(exposure)
      shown = exposure.shown_by
      shown ? "#{exposure.doing}, shown by #{shown}" : exposure.doing
    end

    # DeclarativePolicy hazards (D3, D4) in the abilities read from code,
    # and GraphQL's (G4, G5).
    # A G5 lint names the list checks of its type's `scope_items` (phase 3
    # step 7), which check at run time what the lint suspects.
    def self.lints_of(analysis)
      lints = (analysis.inference&.extractor&.lints || []) + (analysis.graphql&.lints || [])
      lints.map { |lint| Report.linked(lint, analysis) }
    end

    def self.linked(lint, analysis)
      subject = lint.subject
      return lint unless lint.kind == "G5" && subject

      rule = "#{subject}##{ListScope::GRAPHQL_RULE}"
      checks = analysis.exposures.select { |exposure| exposure.list? && (exposure.rules || []).include?(rule) }
      return lint if checks.empty?

      lint.class.new(kind: lint.kind, location: lint.location, subject: subject,
                     message: "#{lint.message}; where it runs, its lists are checked: " \
                              "#{checks.map(&:check_name).join(", ")}")
    end

    # What kind of hazard a lint is: DeclarativePolicy's D3 and D4,
    # GraphQL's G4 and G5, or the revocation lint's R1.
    def self.hazard(lint)
      return "GraphQL hazard" if lint.kind.start_with?("G")

      lint.kind.start_with?("R") ? "revocation hazard" : "policy-DSL hazard"
    end

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
      out << "#{count(stale_access.size, "stale allow")} after revocation" if stale_access.any?
      lints.group_by { |lint| Report.hazard(lint) }.each { |kind, found| out << count(found.size, kind) }
      out << unknown_summary(total) if unknown.any?
      out
    end

    # The checks' outcome beside other problems; never "no counterexample"
    # next to an unknown, which is not one.
    def verdicts(total)
      return "#{count(findings.size, "counterexample")} in #{count(total, "check")}" if findings.any?
      return nil unless unknown.empty? && (unchecked.any? || drift.any? || stale_access.any? || lints.any?)

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

    # The stale access section: each allow after a revocation that neither
    # the rule's code nor another allow-stamp explains.
    def stale_access_lines
      return [] if stale_access.empty?

      lines = ["", "Stale access after revocation (allows after the user lost a role that nothing else explains):"]
      stale_access.each { |item| lines.concat(Report.stale_lines(item)) }
      lines
    end

    def self.stale_lines(item)
      at = " at #{item.location}" if item.location
      ["STALE #{item.rule} (#{item.resource})#{at}: allowed after the user lost #{item.revoked.join(", ")} in " \
       "#{item.tenant}, but neither its code nor any other allow-stamp allows #{item.facts}",
       "      stamped at: #{item.seen.join(", ")}",
       "      look for a role read cached across requests (the R1 lints, or `hallmark extract`'s role reads), " \
       "or a rule no test exercised with these facts"]
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
      lines.concat(coverage_notes(coverage))
      coverage_lists(coverage).each do |title, names|
        lines << "  #{title}: #{names.join(", ")}" if names.any?
      end
      lines.concat(route_lines(coverage))
    end

    # The notes printed after the per-rule gaps, before the lists.
    def coverage_notes(coverage) = opaque_lines(coverage) + mismatch_lines(coverage)

    # Calls inside rules the extractor could not read (docs/adr/0003).
    def opaque_lines(coverage)
      return [] if coverage.opaque.empty?

      ["  Calls in rules and controller checks that Hallmark could not read (the checked guard assumes each one " \
       "denies):",
       *coverage.opaque.map { |entry| "    #{entry}" }]
    end

    # GraphQL requests whose context's current tenant was not the
    # controller's (G6). Stamps of type checks read the context's; the model
    # checks every current tenant either way.
    def mismatch_lines(coverage)
      return [] if coverage.mismatches.empty?

      ["  GraphQL requests whose context names another current tenant than the controller's (G6):",
       *coverage.mismatches.map { |mismatch| "    #{mismatch}" }]
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
        "Rules with allow-stamps recorded before their resource's facts were mapped, not read into the guard " \
        "(run the suite again)" => coverage.stale.uniq,
        "Entry points not checked: their controller's own check depends on calls Hallmark could not read" =>
          coverage.checks_unread,
        "Lists with no record observed and no scope read from code (nothing to check)" => coverage.lists_unobserved,
        "Lists that may show other tenants' records (declare `lists: :current_tenant` on the resource if they " \
        "should not)" => coverage.cross_tenant_lists
      }.merge(revocation_lists(coverage))
    end

    # Revocation's coverage lists (phase 3 step 9).
    def revocation_lists(coverage)
      {
        "Allows after a revocation that other access explains" => coverage.stale_explained,
        "Allows after a revocation Hallmark could not judge" => coverage.stale_unjudged,
        "Decisions after a revocation whose roles, as `roles_in:` read them, still held the revoked role" =>
          coverage.revoked_reads,
        "Revocations not watched" => coverage.unwatched,
        "Role reads cached on purpose (`cache_ok`)" => coverage.caches_accepted
      }
    end

    # Routes no test reached, which can be many in a whole app, and the
    # calls the revocation lint could not follow: each list shows its first
    # ROUTES_SHOWN names and counts the rest.
    def route_lists(coverage)
      {
        "Role reads the revocation lint could not follow" => coverage.role_reads_unread,
        "Routes no test reached whose code authorizes a record Hallmark could not resolve to a rule" =>
          coverage.routes_unresolved,
        "Routes no test reached with no authorization call in the code Hallmark reads" =>
          coverage.routes_unchecked,
        "Routes no test reached in controllers outside app/controllers" => coverage.routes_unread
      }
    end

    # What follows the summary: coverage, the GraphQL walk's notes, the
    # REST serializers' notes and the fields with no policy.
    def trailer_lines = coverage_lines + graphql_lines + serializer_lines + field_lines

    # What the REST serializer reader did not check (phase 3 step 8,
    # `Inference::SerializerNotes`). Never findings.
    def serializer_lines
      notes = analysis.inference&.serializer_notes
      return [] if notes.nil? || notes.empty?

      lines = ["", "REST serializers (coverage, not findings):"]
      notes.lists.each { |title, items| lines.concat(note_lines(title, items)) unless items.empty? }
      lines << "  Serializers no entry point renders: #{notes.unrendered}" if notes.unrendered.positive?
      lines << "  Jbuilder views (not read): #{notes.jbuilder}" if notes.jbuilder.positive?
      lines
    end

    # What the GraphQL schema walk could not model (`GraphqlModel#notes`).
    # Never findings.
    def graphql_lines
      model = analysis.graphql
      return [] unless model

      notes = model.notes.reject { |_, items| items.empty? }
      cut = model.cut
      return [] if notes.empty? && cut.zero?

      lines = ["", "GraphQL schema walk (coverage, not findings):"]
      notes.each { |title, items| lines.concat(note_lines(title, items)) }
      lines << "  Paths cut after #{GraphqlModel::MAX_UNMAPPED} types that back no resource: #{cut}" if cut.positive?
      lines
    end

    # A titled list showing its first GraphqlModel::SHOWN items.
    def note_lines(title, items)
      hidden = items.size - GraphqlModel::SHOWN
      lines = ["  #{title} (#{items.size}):", *items.first(GraphqlModel::SHOWN).map { |item| "    #{item}" }]
      hidden.positive? ? lines << "    and #{hidden} more" : lines
    end

    # Field reads with no field policy: checked as readable as their record.
    # A warning, not a finding.
    def field_lines
      open = analysis.fields_without_policy
      return [] if open.empty?

      ["", "Fields with no field policy (checked as readable as their record; declare `field_policy` to narrow):",
       *open.map { |exposure| "  #{exposure.action} (#{exposure.doing})" }]
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
