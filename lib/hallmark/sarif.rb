# typed: strict
# frozen_string_literal: true

require "digest"
require "json"

module Hallmark
  # A SARIF 2.1.0 log of what fails `hallmark check` (phase 2 step 5), for
  # code scanning: counterexamples, unchecked entry points (threat 10),
  # drift and DeclarativePolicy hazards. Coverage is left out; it is not a
  # finding. Each result points at the source lines behind it, relative to
  # the app root: a counterexample at the entry point's authorize call or
  # Grape endpoint, then the rules' code; an unchecked entry point at its
  # action; drift at the rule; a hazard at its condition or rule. A result
  # with no line in the app's code (a hand-declared exposure) points at
  # `fallback`, the mapping file. `partialFingerprints` keep a result's
  # identity across runs.
  #
  #   File.write("hallmark.sarif", Hallmark::Sarif.new(reports, fallback: "config/hallmark.rb").to_json)
  class Sarif
    SCHEMA = "https://json.schemastore.org/sarif-2.1.0.json"
    INFORMATION_URI = "https://gitlab.com/namelessnotion/hallmark"

    # One rule a result can break: its id, a one-line name and its help.
    Rule = Struct.new(:id, :short, :help, keyword_init: true) do
      def to_h
        { "id" => id, "name" => id.delete_prefix("hallmark/"), "shortDescription" => { "text" => short },
          "fullDescription" => { "text" => help }, "defaultConfiguration" => { "level" => "error" },
          "help" => { "text" => help } }
      end
    end

    # The rules, in the order the log lists them.
    def self.rules = core_rules + graphql_rules

    def self.core_rules
      [
        Rule.new(id: "hallmark/counterexample", short: "Access no catalog pattern allows",
                 help: "The guard lets a principal reach a record in a way no access pattern in the catalog " \
                       "allows. The message names who, holding which roles, can do what to whose record."),
        Rule.new(id: "hallmark/unchecked", short: "Entry point served without authorization",
                 help: "A request finished without any authorization call (threat 10)."),
        Rule.new(id: "hallmark/drift", short: "Stamped decision the rule's code contradicts",
                 help: "A decision the test suite recorded disagrees with the guard read from the rule's code: " \
                       "the extractor or a mapped term is wrong, so checks built on that guard are suspect."),
        Rule.new(id: "hallmark/D3", short: "Condition cached at the wrong scope",
                 help: "A DeclarativePolicy condition is cached at a scope that leaves out what its body reads, " \
                       "so one user's or subject's answer is reused for another."),
        Rule.new(id: "hallmark/D4", short: "Ruby boolean operator in a rule block",
                 help: "DeclarativePolicy conditions are objects, so &&, || and ! do not combine them; " \
                       "use &, | and ~.")
      ]
    end

    def self.graphql_rules
      [
        Rule.new(id: "hallmark/G4", short: "GraphQL mutation checked late or not at all",
                 help: "A mutation has no ready?, authorized? or authorize of its own and authorizes nothing in " \
                       "resolve, is mounted with Action Policy's authorize: (which runs after it executed), or " \
                       "overrides a load_ method so the loaded object's type check never runs."),
        Rule.new(id: "hallmark/G5", short: "GraphQL scope switched off",
                 help: "A list field sets scope: false, or a type turns off reauthorize_scoped_objects with a " \
                       "scope_items that reads no tenant, so list members are not checked as the type's own " \
                       "objects are.")
      ]
    end

    def initialize(reports, fallback: nil)
      @reports = reports
      @fallback = fallback
    end

    def to_h
      {
        "$schema" => SCHEMA, "version" => "2.1.0",
        "runs" => [{
          "tool" => { "driver" => { "name" => "Hallmark", "version" => VERSION, "informationUri" => INFORMATION_URI,
                                    "rules" => Sarif.rules.map(&:to_h) } },
          "results" => @reports.flat_map { |report| results(report) }
        }]
      }
    end

    def to_json(*) = JSON.pretty_generate(to_h)

    private

    def results(report)
      findings = report.findings.map { |finding| finding_result(finding) }
      unchecked = report.unchecked.map { |entry_point| unchecked_result(report, entry_point) }
      drift = report.drift.map { |item| drift_result(item) }
      lints = report.lints.map { |lint| result("hallmark/#{lint.kind}", lint.message, [lint.location], lint.to_s) }
      findings + unchecked + drift + lints
    end

    def finding_result(finding)
      exposure = finding.exposure
      hint = finding.hint
      intended = finding.intended
      path = finding.path
      text = "#{exposure.action} (#{exposure.op} #{exposure.target}): #{finding.message}." \
             "#{" Path: #{path}." if path} " \
             "Intended pattern: #{finding.pattern}.#{" Intended: #{intended}." if intended}" \
             "#{" #{hint[0].to_s.upcase}#{hint[1..]}." if hint}"
      result("hallmark/counterexample", text, exposure.locations || [], exposure.check_name)
    end

    def unchecked_result(report, entry_point)
      location = report.extractor&.controllers&.action_location(entry_point)
      result("hallmark/unchecked", "#{entry_point} finished without an authorization call (threat 10).",
             [location].compact, entry_point)
    end

    def drift_result(item)
      text = Report.drift_lines(item).map(&:strip).join(" ").delete_prefix("DRIFT ")
      result("hallmark/drift", text, [item.location], item.key)
    end

    # A result at the first location, the rest related.
    def result(rule, text, locations, identity)
      places = locations.filter_map { |location| physical(location) }
      places = [artifact(@fallback, nil)] if places.empty? && @fallback
      out = { "ruleId" => rule, "level" => "error", "message" => { "text" => text },
              "partialFingerprints" => { "hallmark/v1" => Digest::SHA256.hexdigest("#{rule}|#{identity}") } }
      first, *rest = places
      out["locations"] = [first] if first
      out["relatedLocations"] = rest.each_with_index.map { |place, index| place.merge("id" => index + 1) } if rest.any?
      out
    end

    # "app/policies/link_policy.rb:21" as a SARIF physical location.
    def physical(location)
      match = location.match(/\A(.+):(\d+)\z/)
      match ? artifact(match[1].to_s, Integer(match[2])) : nil
    end

    def artifact(uri, line)
      place = { "artifactLocation" => { "uri" => uri } }
      place["region"] = { "startLine" => line } if line
      { "physicalLocation" => place }
    end
  end
end
