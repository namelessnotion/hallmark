# frozen_string_literal: true

# What the collectors add to an app's own requests (the phase 3 gate's
# hot path item), measured inside the booted app the way `rake bench`
# measures the test shop (bench/measure.rb has the states and columns):
#
#   BENCH_SCENARIOS=path/to/scenarios.rb bin/rails runner path/to/hallmark/bench/app.rb
#
# The scenarios file calls `HotPath.scenario "name" do ... end` once per
# thing to measure (a request through `Rails.application.call`, a policy
# call), with whatever setup it needs from the app's data. The mapping is
# the app's (`Hallmark.configuration`, else config/hallmark.rb); the
# collectors are installed here with a store in a temporary directory, so
# the app's own Hallmark mode does not matter. Stamps are written, and
# discarded with the directory. Each timed call waits, off the clock, for
# the store's flusher to finish (`settle:`): a full request is long enough
# that the flusher's thread would otherwise run inside the next call,
# charging `off` for `on`'s write.
#
# Beside the shop's table it prints, per scenario: the decisions one call
# makes (each stamp `Collectors.decision` takes), Hallmark's own time per sampled
# decision (the call's own p50 and p99 divided by them), and the sample
# rate 0.01 two ways, as microseconds per call over `off` at the mean:
# expected (0.99 skip + 0.01 on) and measured (one more pass at that rate).
# BENCH_N sets the calls per state (default 20000) and BENCH_WARMUP the
# untimed calls before each state (default 2000), and BENCH_BATCH the
# calls per GC-free batch (default 1000); a slow app's requests want all
# three lower (Gumroad in development: 2000, 200 and 20).

require "hallmark"
require "tmpdir"
require_relative "measure"

# The app harness: scenarios the app declares, counted decisions, and the
# per-decision table.
module HotPath
  # Counts the decisions the collectors stamp.
  module DecisionCount
    def decision(...)
      HotPath.decisions += 1
      super
    end
  end

  # One scenario's decisions per call and its pass at rate 0.01.
  AppResult = Struct.new(:result, :decisions, :sampled)

  RATE = 0.01

  class << self
    attr_writer :decisions

    def decisions = @decisions ||= 0
    def scenarios = @scenarios ||= []

    # Declares a call to measure; the block runs once per call.
    def scenario(name, &call) = scenarios << [name, call]

    def run_app(scenarios_file = ENV.fetch("BENCH_SCENARIOS"))
      mapping = app_mapping
      load scenarios_file
      raise ArgumentError, "#{scenarios_file} declares no `HotPath.scenario`" if scenarios.empty?

      bare = scenarios.map { |_, call| [time_bare(call), allocations(call)] }
      Hallmark::Collectors::Facts.prepend(ReaderClock)
      Hallmark::Collectors.singleton_class.prepend(DecisionCount)
      Dir.mktmpdir("hallmark-bench") do |dir|
        Hallmark::Collectors.install!(mapping: mapping, store: Hallmark::StampStore.new(dir, run: "bench"))
        results = scenarios.zip(bare).map { |(name, call), (times, allocs)| measure_app(name, call, times, allocs) }
        Hallmark::Collectors.uninstall!
        print_app(results)
      end
    end

    private

    def app_mapping
      mapping = Hallmark.configuration.mapping
      return mapping if mapping

      file = File.join(Hallmark.configuration.root, "config", "hallmark.rb")
      load file
      Hallmark.configuration.mapping || raise(ArgumentError, "#{file} declares no mapping")
    end

    def measure_app(name, call, bare_times, bare_allocs)
      switch(:on)
      self.decisions = 0
      call.call
      decisions = self.decisions
      result = measure_installed(name, call, bare_times, bare_allocs, settle: true)
      switch(:on, rate: RATE)
      sampled = []
      batches do
        sampled << timed(call)
        Hallmark::Collectors.flush
      end
      switch(:on)
      AppResult.new(result, decisions, sampled)
    end

    def mean(values) = values.sum / values.size

    def print_app(results)
      puts "Hallmark #{Hallmark::VERSION}, #{RUBY_DESCRIPTION}"
      puts "#{N} calls per state per scenario; microseconds per call; allocs are objects per call", ""
      width = [32, *results.map { |found| found.result.name.size }].max
      title = header(width)
      puts title, "-" * title.size
      results.each { |found| puts row(found.result, width) }
      puts "", per_decision_header(width)
      results.each { |found| puts per_decision(found, width) }
    end

    def per_decision_header(width)
      titles = ["decisions", "own p50/d", "own p99/d", "1% expect", "1% meas"].map { |title| title.rjust(9) }
      ["scenario".ljust(width), *titles].join(" ")
    end

    def per_decision(found, width)
      result = found.result
      own50, own99 = values(result).values_at(2, 3)
      count = [found.decisions, 1].max
      times = result.times
      off = mean(times.fetch(:off))
      expected = ((1 - RATE) * mean(times.fetch(:skip))) + (RATE * mean(times.fetch(:on))) - off
      numbers = [found.decisions, own50 / count, own99 / count, expected, mean(found.sampled) - off]
      [result.name.ljust(width), format("%9d", numbers.first),
       *numbers.drop(1).map { |value| format("%9.2f", value) }].join(" ")
    end
  end
end

HotPath.run_app
