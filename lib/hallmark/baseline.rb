# typed: strict
# frozen_string_literal: true

require "digest"
require "json"

module Hallmark
  # What CI knew, for `hallmark watch` (phase 3 step 3): written once per
  # build by `hallmark check --baseline OUT`, as one self-contained JSON
  # file. It holds the Hallmark and Alloy versions and the scope the checks
  # ran at, a digest of the mapping file's bytes, the run its stamps came
  # from, every stamp, unchecked and route line of that run, and per check
  # its exposure's digest (`Exposure#digest`) and verdict, plus the
  # unchecked entry points and drift that failed. Watch seeds its stamps
  # from these lines, so its guards start equal to CI's and only live
  # stamps change them.
  #
  #   baseline = Baseline.build(reports, mapping_digest: Baseline.digest_files(["config/hallmark.rb"]), run: "ci")
  #   baseline.write("hallmark-baseline.json")
  class Baseline
    FORMAT = 1

    # One check as CI ran it: `verdict` is "counterexample", "none" (none
    # within scope) or "unknown".
    Check = Struct.new(:name, :action, :op, :resource, :digest, :verdict, keyword_init: true) do
      def counterexample? = verdict == "counterexample"
      def unknown? = verdict == "unknown"

      def to_json_object
        { "check" => name, "action" => action, "op" => op.to_s, "resource" => resource, "digest" => digest,
          "verdict" => verdict }
      end
    end

    attr_reader :hallmark, :alloy, :scope, :mapping_digest, :run, :lines, :checks, :unchecked, :drift

    # The baseline of a `hallmark check` run's reports.
    def self.build(reports, mapping_digest:, run:, scope: Hallmark.configuration.scope)
      new(hallmark: VERSION, alloy: ALLOY_VERSION, scope: scope, mapping_digest: mapping_digest, run: run,
          lines: reports.flat_map { |report| lines_of(report.analysis.inference&.stamp_set) }.uniq,
          checks: reports.flat_map { |report| checks_of(report) },
          unchecked: reports.flat_map(&:unchecked).uniq.sort,
          drift: reports.flat_map { |report| report.drift.map(&:key) }.uniq.sort)
    end

    # SHA-256 of the mapping files' bytes, in order.
    def self.digest_files(files) = Digest::SHA256.hexdigest(files.map { |file| File.binread(file) }.join)

    def self.load(path)
      data = JSON.parse(File.read(path))
      unless data.is_a?(Hash) && data.key?("format")
        raise ConfigurationError, "#{path} is not a Hallmark baseline (write one with `hallmark check --baseline`)"
      end
      unless data["format"] == FORMAT
        raise ConfigurationError, "#{path} is a baseline in format #{data["format"]}; this Hallmark reads " \
                                  "format #{FORMAT}, so write it again with `hallmark check --baseline`"
      end

      from_data(data)
    rescue JSON::ParserError => e
      raise ConfigurationError, "#{path} is not a Hallmark baseline: #{e.message}"
    end

    def self.from_data(data)
      checks = data.fetch("checks").map do |check|
        Check.new(name: check.fetch("check"), action: check.fetch("action"), op: check.fetch("op").to_sym,
                  resource: check.fetch("resource"), digest: check.fetch("digest"), verdict: check.fetch("verdict"))
      end
      new(hallmark: data.fetch("hallmark"), alloy: data.fetch("alloy"), scope: data.fetch("scope"),
          mapping_digest: data.fetch("mapping_digest"), run: data["run"], lines: data.fetch("lines"),
          checks: checks, unchecked: data.fetch("unchecked"), drift: data.fetch("drift"))
    end

    # Every exposure of a report with its verdict.
    def self.checks_of(report)
      mapping = report.analysis.mapping
      verdicts = report.findings.to_h { |finding| [finding.exposure.check_name, "counterexample"] }
      report.unknown.each { |item| verdicts[item.exposure.check_name] = "unknown" }
      report.analysis.exposures.map do |exposure|
        name = exposure.check_name
        Check.new(name: name, action: exposure.action, op: exposure.op, resource: exposure.resource,
                  digest: exposure.digest(mapping), verdict: verdicts.fetch(name, "none"))
      end
    end
    private_class_method :checks_of

    # A stamp set as the lines the collectors write (examples left out).
    def self.lines_of(set)
      return [] unless set

      [set.stamps, set.unchecked, set.routes, set.mismatches].flat_map { |events| events.map(&:to_json_line) }
    end

    def initialize(hallmark:, alloy:, scope:, mapping_digest:, run:, lines:, checks:, unchecked:, drift:)
      @hallmark = hallmark
      @alloy = alloy
      @scope = scope
      @mapping_digest = mapping_digest
      @run = run
      @lines = lines
      @checks = checks
      @unchecked = unchecked
      @drift = drift
    end

    # The stamps the baseline was built from.
    def stamp_set = StampSet.parse(lines)

    def failing = checks.select(&:counterexample?)

    # Why the verdict table no longer describes the checks this process
    # would build: empty when it still does.
    def stale_reasons(mapping_digest:, scope: Hallmark.configuration.scope)
      reasons = []
      reasons << "the mapping file changed" unless mapping_digest == self.mapping_digest
      reasons << "it was checked at scope #{self.scope}, not #{scope}" unless scope == self.scope
      reasons << "it was written by Hallmark #{hallmark}, not #{VERSION}" unless hallmark == VERSION
      reasons << "it was checked with Alloy #{alloy}, not #{ALLOY_VERSION}" unless alloy == ALLOY_VERSION
      reasons
    end

    def to_h
      { "format" => FORMAT, "hallmark" => hallmark, "alloy" => alloy, "scope" => scope,
        "mapping_digest" => mapping_digest, "run" => run, "checks" => checks.map(&:to_json_object),
        "unchecked" => unchecked, "drift" => drift, "lines" => lines }
    end

    def to_json(*) = JSON.pretty_generate(to_h)

    def write(path) = File.write(path, to_json)
  end
end
