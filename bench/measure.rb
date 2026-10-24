# frozen_string_literal: true

# What `bench/hot_path.rb` (the test shop) and `bench/app.rb` (a booted
# app) share: the three states the collectors cycle through each
# iteration, so that all three see the same noise (a Rails request's own
# tail varies by tens of microseconds between runs),
#
#   off      the collectors switched off (`Collectors.active?` false)
#   skip     on, but the decision not sampled (sample rate 0)
#   on       on and sampled
#
# the time spent in mapping readers (app code), allocations, and the
# table both print, in microseconds per call:
#
#   bare     the call with no hooks at all
#   idle     off minus bare, at the median: hooks installed but switched off,
#            which only happens after `uninstall!` (production modes that are
#            off never install them)
#   own      on, less the time in mapping readers, minus off, at the median
#            and at p99. Percentiles are taken of each state's times, then
#            subtracted.
#   read     time in the mapping's readers (principal roles, roles in a
#            tenant, owner, permits:), which are the app's code
#   allocs   objects allocated per call beyond the bare call, process-wide
#            (so the flusher thread's work counts)
#   skip     skip minus off, at the median and p99: what every decision pays
#            in sampled mode when it is not sampled, and its allocations
#
# Timed loops run with GC off, in batches with a full GC between them, so a
# pause does not land on one call; allocations are reported instead.
module HotPath
  N = Integer(ENV.fetch("BENCH_N", 20_000))
  # macOS's CLOCK_MONOTONIC ticks in whole microseconds; the raw clock in tens of nanoseconds.
  CLOCK = defined?(Process::CLOCK_MONOTONIC_RAW) ? Process::CLOCK_MONOTONIC_RAW : Process::CLOCK_MONOTONIC
  # Calls per GC-free batch; a heavy app request allocates enough that a
  # thousand without GC can exhaust memory, so lower it with BENCH_BATCH.
  BATCH = [Integer(ENV.fetch("BENCH_BATCH", 1_000)), N].min
  WARMUP = Integer(ENV.fetch("BENCH_WARMUP", 2_000))
  STATES = %i[off skip on].freeze

  # Accumulates time spent in mapping readers on this thread, in a thread
  # variable rather than a fiber-local, since graphql-ruby may resolve
  # fields in fibers. Prepended on Collectors::Facts, whose `read` is the
  # one way facts reach app code.
  module ReaderClock
    private

    def read(...)
      start = HotPath.now
      super
    ensure
      HotPath.readers += HotPath.now - start
    end
  end

  # Times per state (`:bare` and STATES), readers' times in the `on` state,
  # and allocations per call per state.
  Result = Struct.new(:name, :times, :readers, :allocs, :fields)

  class << self
    def now = Process.clock_gettime(CLOCK, :nanosecond) / 1000.0
    def readers = Thread.current.thread_variable_get(:hallmark_bench_readers) || 0.0

    def readers=(value)
      Thread.current.thread_variable_set(:hallmark_bench_readers, value)
    end

    def time_bare(call)
      WARMUP.times { call.call }
      times = []
      batches { times << timed(call) }
      times
    end

    # Cycles through the states each iteration; only the `on` state reads
    # facts. With `settle`, waits off the clock for the stamp store's
    # flusher after each call, so its thread does not run during the next
    # state's call (it writes off the request path, and its objects still
    # count in the allocations).
    def measure_installed(name, call, bare_times, bare_allocs, fields: nil, settle: false)
      STATES.each do |state|
        switch(state)
        WARMUP.times { call.call }
      end
      times = STATES.to_h { |state| [state, []] }
      readers = []
      batches do
        STATES.each do |state|
          switch(state)
          HotPath.readers = 0.0
          times.fetch(state) << timed(call)
          readers << HotPath.readers if state == :on
          Hallmark::Collectors.flush if settle
        end
      end
      allocs = STATES.to_h do |state|
        switch(state)
        [state, allocations(call)]
      end
      switch(:on)
      Result.new(name, times.merge(bare: bare_times), readers, allocs.merge(bare: bare_allocs), fields)
    end

    # The state the collectors are in, set off the clock. Writes their
    # instance variables directly: the bench toggles them per call, and
    # `install!` and `uninstall!` do far more than that.
    def switch(state, rate: nil)
      Hallmark::Collectors.instance_variable_set(:@active, state != :off)
      Hallmark::Collectors.instance_variable_set(:@sample_rate, rate || (state == :skip ? 0.0 : 1.0))
    end

    def batches(&iteration)
      (N / BATCH).times do
        GC.start
        GC.disable
        BATCH.times(&iteration)
        GC.enable
      end
    end

    def timed(call)
      start = now
      call.call
      now - start
    end

    def allocations(call)
      GC.start
      before = GC.stat(:total_allocated_objects)
      N.times { call.call }
      Hallmark::Collectors.flush
      (GC.stat(:total_allocated_objects) - before).fdiv(N)
    end

    def percentile(values, pct)
      sorted = values.sort
      sorted.fetch(((pct / 100.0) * (sorted.size - 1)).round)
    end

    def header(width = 32)
      titles = ["bare p50", "idle p50", "own p50", "own p99", "read p50", "read p99", "allocs", "skip p50",
                "skip p99", "skip allocs"].map { |title| title.rjust(9) }
      ["scenario".ljust(width), *titles].join(" ")
    end

    def values(result)
      times = result.times
      own = times.fetch(:on).zip(result.readers).map { |time, read| time - read }
      off = times.fetch(:off)
      bare = percentile(times.fetch(:bare), 50)
      [bare, percentile(off, 50) - bare,
       percentile(own, 50) - percentile(off, 50), percentile(own, 99) - percentile(off, 99),
       percentile(result.readers, 50), percentile(result.readers, 99),
       result.allocs.fetch(:on) - result.allocs.fetch(:bare),
       percentile(times.fetch(:skip), 50) - percentile(off, 50),
       percentile(times.fetch(:skip), 99) - percentile(off, 99),
       result.allocs.fetch(:skip) - result.allocs.fetch(:bare)]
    end

    def row(result, width = 32)
      [result.name.ljust(width), *values(result).map { |value| format("%9.2f", value) }].join(" ")
    end
  end
end
