# typed: strict
# frozen_string_literal: true

require "json"

module Hallmark
  class Watch
    # One thing a batch found: `type` is :finding, :unchecked, :drift,
    # :resolved (a check no longer fails) or :unknown; `data` the fields of
    # its JSON object; `lines` its text, worded as `hallmark check` words it.
    # `c.on_finding` gets every event but unknown ones.
    Event = Struct.new(:type, :data, :lines, keyword_init: true) do
      def to_h = { "type" => type.to_s }.merge(data)
      def to_json(*) = JSON.generate(to_h)
      def failure? = %i[finding unchecked drift].include?(type)

      # A new counterexample, with the example its live stamps were first
      # seen with, when ids were recorded (docs/adr/0004).
      def self.finding(finding, example)
        exposure = finding.exposure
        lines = Report.finding_lines(finding)
        lines << "      #{example_line(example)}" if example
        data = exposure_data(exposure).merge(
          "guard" => exposure.guard.to_s, "basis" => exposure.basis, "message" => finding.message,
          "pattern" => finding.pattern, "hint" => finding.hint, "example" => example&.to_json_object
        )
        new(type: :finding, data: data, lines: lines)
      end

      def self.resolved(exposure)
        new(type: :resolved, data: exposure_data(exposure),
            lines: ["ok    #{exposure.action} (#{exposure.op} #{exposure.target}): no longer fails, " \
                    "no counterexample within scope #{Hallmark.configuration.scope}"])
      end

      def self.unknown(item)
        new(type: :unknown, data: exposure_data(item.exposure).merge("reason" => item.reason),
            lines: [Report.unknown_line(item.exposure, item.reason)])
      end

      def self.unchecked(entry_point)
        new(type: :unchecked, data: { "entry_point" => entry_point },
            lines: ["FAIL  #{entry_point} finished without an authorization call (threat 10)"])
      end

      def self.drift(item)
        data = { "rule" => item.rule, "resource" => item.resource, "decision" => item.decision,
                 "bound" => item.bound.to_s, "facts" => item.facts, "location" => item.location, "seen" => item.seen,
                 "raised" => item.raised }
        new(type: :drift, data: data, lines: Report.drift_lines(item))
      end

      def self.exposure_data(exposure)
        data = { "check" => exposure.check_name, "action" => exposure.action, "op" => exposure.op.to_s,
                 "resource" => exposure.resource }
        (field = exposure.field) ? data.merge("field" => field) : data
      end

      # "first seen as user h:<first 12 hex>, record h:..., tenant h:..."
      def self.example_line(example)
        parts = { "user" => example.user, "record" => example.record, "tenant" => example.tenant }
                .filter_map { |name, digest| "#{name} h:#{digest[0, 12]}" if digest }
        "first seen as #{parts.join(", ")}"
      end
    end

    # One batch: lines read, stamps new to the watch, checks sent to the
    # solver, the events reported and the verdicts that were not news.
    Batch = Struct.new(:lines, :stamps, :checks, :events, :known, :none, keyword_init: true) do
      # One line: the time, the new stamps and what the checks found.
      def summary
        counts = events.group_by(&:type).transform_values(&:size)
        parts = [count(stamps, "new stamp"),
                 checks.zero? ? "no check changed" : "#{count(checks, "check")} run: #{verdicts(counts).join(", ")}"]
        parts << count(counts.fetch(:unchecked), "new unchecked entry point") if counts.key?(:unchecked)
        parts << count(counts.fetch(:drift), "new drifting decision") if counts.key?(:drift)
        "#{Time.now.utc.strftime("%H:%M:%S")} #{parts.join("; ")}."
      end

      def verdicts(counts)
        out = [count(counts.fetch(:finding, 0), "new counterexample")]
        out << "#{known} already known" if known.positive?
        out << "#{none} with none within scope #{Hallmark.configuration.scope}" if none.positive?
        out << "#{counts.fetch(:unknown)} unknown" if counts.key?(:unknown)
        out << "#{counts.fetch(:resolved)} no longer failing" if counts.key?(:resolved)
        out
      end

      def count(number, noun) = "#{number} #{noun}#{"s" unless number == 1}"
    end
  end
end
