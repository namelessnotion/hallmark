# frozen_string_literal: true

module Hallmark
  # The outcome of one analysis run: a finding per exposure that has a
  # counterexample, and the list of exposures that hold within scope.
  class Report
    attr_reader :analysis, :findings, :verified

    def initialize(analysis, receipt)
      @analysis = analysis
      @findings = []
      @verified = []
      analysis.exposures.each do |exposure|
        command = receipt[exposure.check_name]
        raise SolverError, "Alloy returned no result for #{exposure.action}" unless command

        if command.counterexample?
          @findings << Finding.from(exposure, command.instance, analysis.mapping)
        else
          @verified << exposure
        end
      end
    end

    def clean? = findings.empty?
    def exit_code = clean? ? 0 : 1

    def to_s
      lines = ["Hallmark #{VERSION}, #{analysis.name}, Alloy #{ALLOY_VERSION}, scope #{Hallmark.configuration.scope}", ""]
      findings.each do |finding|
        exposure = finding.exposure
        lines << "FAIL  #{exposure.action} (#{exposure.op} #{exposure.resource})"
        lines << "      guard: #{exposure.guard}"
        lines << "      #{finding.message}"
        lines << "      intended pattern: #{finding.pattern}"
        lines << "      #{finding.hint}" if finding.hint
      end
      verified.each do |exposure|
        lines << "ok    #{exposure.action} (#{exposure.op} #{exposure.resource})"
      end
      lines << ""
      lines << summary
      lines.join("\n")
    end

    def summary
      total = findings.size + verified.size
      return "No counterexamples in #{total} checks (bounded: scope #{Hallmark.configuration.scope})." if clean?

      "#{findings.size} counterexample#{"s" unless findings.size == 1} in #{total} checks."
    end
  end
end
