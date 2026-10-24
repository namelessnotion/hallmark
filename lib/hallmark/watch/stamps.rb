# typed: strict
# frozen_string_literal: true

require "json"

module Hallmark
  class Watch
    # The stamps a watch has folded in: the baseline's, then each batch's
    # new lines (stamps, unchecked requests, routes, GraphQL context
    # mismatches, and the example each stamp was first seen with). Stamps keep the order they were first
    # read in, and those not in the baseline are live.
    class Stamps
      # `set` is the stamp set the baseline was built from.
      def initialize(set, err: $stderr)
        @err = err
        @stamps = set.stamps.dup
        @unchecked = set.unchecked.dup
        @routes = set.routes.dup
        @mismatches = set.mismatches.dup
        @revoked_reads = set.revoked_reads.dup
        @unwatched = set.unwatched.dup
        @examples = {}
        add_examples(set)
        @seen = Set.new(@stamps)
        @baseline = Set.new(@stamps)
      end

      # Everything folded in so far, as one stamp set for Inference.
      def set
        StampSet.new(@stamps, @unchecked, @routes, examples: @examples, mismatches: @mismatches,
                                                   revoked_reads: @revoked_reads, unwatched: @unwatched)
      end

      # Adds the lines; returns the stamps new to the watch, in the order read.
      def fold(lines)
        set = parse(lines)
        fresh = set.stamps.reject { |stamp| @seen.include?(stamp) }
        fresh.each { |stamp| @seen << stamp }
        @stamps.concat(fresh)
        @unchecked |= set.unchecked
        @routes |= set.routes
        @mismatches |= set.mismatches
        @revoked_reads |= set.revoked_reads
        @unwatched |= set.unwatched
        add_examples(set)
        fresh
      end

      # The first-seen example of the live allow-stamps of the exposure's
      # rules on its resource, those at its entry point first (docs/adr/0004).
      def example_for(exposure)
        rules = exposure.rules || []
        live = @stamps.select { |stamp| live_allow?(stamp, rules, exposure.resource) }
        chosen = live.find { |stamp| stamp.entry_point == exposure.action } || live.first
        chosen && @examples[chosen]
      end

      private

      # Keeps each stamp's first example that names anything: a user, record
      # or tenant with no id gives none.
      def add_examples(set)
        set.examples.each do |stamp, example|
          @examples[stamp] ||= example if example.to_h.values.any?
        end
      end

      def live_allow?(stamp, rules, resource)
        stamp.allow? && rules.include?(stamp.rule_key) && stamp.resource.to_s == resource && @examples.key?(stamp) &&
          !@baseline.include?(stamp)
      end

      # A line that is not JSON (a torn write, another program's output) is
      # skipped with a warning rather than stopping the watch.
      def parse(lines)
        StampSet.parse(lines)
      rescue JSON::ParserError
        good = lines.select do |line|
          JSON.parse(line)
          true
        rescue JSON::ParserError
          @err.puts "hallmark watch: skipped a line that is not JSON: #{line[0, 80]}"
          false
        end
        StampSet.parse(good)
      end
    end
  end
end
