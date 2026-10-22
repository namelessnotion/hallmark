# frozen_string_literal: true

# Measures what the collectors add to one authorization decision (docs/PLAN.md,
# "Phase 3 plan", step 1). Each scenario runs a rule on the test shop
# (test/support/shop.rb), first with Hallmark not installed (bare), then with
# the collectors installed, cycling every iteration through three states so
# that all three see the same noise (a Rails request's own tail varies by
# tens of microseconds between runs):
#
#   off      the collectors switched off (`Collectors.active?` false)
#   skip     on, but the decision not sampled (sample rate 0)
#   on       on and sampled
#
# and reports, in microseconds per call:
#
#   bare     the call with no hooks at all
#   idle     off minus bare, at the median: hooks installed but switched off,
#            which only happens after `uninstall!` (production modes that are
#            off never install them)
#   own      on, less the time in mapping readers, minus off, at the median
#            and at p99. Percentiles are taken of each state's times, then
#            subtracted.
#   read     time in the mapping's readers (principal roles, roles in a
#            tenant, owner, permits:), which are the app's code; the shop's
#            are in memory, a real app's are often queries
#   allocs   objects allocated per call beyond the bare call, process-wide
#            (so the flusher thread's work counts)
#   skip     skip minus off, at the median and p99: what every decision pays
#            in sampled mode when it is not sampled, and its allocations
#
# The GraphQL rows are one query each (31 fields, then 33 with two
# decisions); below the table, what each field adds over the bare query,
# with the tracer on, not sampled and off.
#
# Timed loops run with GC off, in batches with a full GC between them, so a
# pause does not land on one call; allocations are reported instead.
#
#   bundle exec rake bench
#   BENCH_N=50000 bundle exec ruby -Ilib -Itest bench/hot_path.rb

require "hallmark"
require "tmpdir"
require "support/shop"
require "support/graphql_shop"

# The benchmark: scenarios, measurement and the table it prints.
module HotPath
  N = Integer(ENV.fetch("BENCH_N", 20_000))
  # macOS's CLOCK_MONOTONIC ticks in whole microseconds; the raw clock in tens of nanoseconds.
  CLOCK = defined?(Process::CLOCK_MONOTONIC_RAW) ? Process::CLOCK_MONOTONIC_RAW : Process::CLOCK_MONOTONIC
  BATCH = 1_000
  WARMUP = 2_000
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

  # One rule call, and the shop mapping's current tenant for it (DeclarativePolicy
  # policies have no `seller`, so its scenarios read the session's); a
  # GraphQL query also gives the number of fields it resolves.
  Scenario = Struct.new(:name, :call, :current_tenant, :fields)

  # Times per state (`:bare` and STATES), readers' times in the `on` state,
  # and allocations per call per state.
  Result = Struct.new(:name, :times, :readers, :allocs, :fields)

  # A schema of fifteen items with no checks of their own, beside the
  # shop's link, whose type check and `editable` field each decide.
  module Api
    Item = Struct.new(:id, :name)
    ITEMS = Array.new(15) { |index| Item.new(index.to_s, "item #{index}") }.freeze

    # An item: two scalar fields, no check.
    class ItemType < GraphQL::Schema::Object
      field :id, ID, null: false
      field :name, String, null: false
    end

    # The items, and the shop's link by id.
    class QueryType < GraphQL::Schema::Object
      field :items, [ItemType], null: false
      field :link, GraphqlShop::LinkType do
        argument :id, ID, as: :key
      end

      def items = ITEMS
      def link(key:) = GraphqlShop.links[key]
    end

    # The schema both GraphQL rows query.
    class Schema < GraphQL::Schema
      query QueryType
    end

    QUIET = GraphQL.parse("{ items { id name } }")
    DECIDING = GraphQL.parse('{ items { id name } link(id: "1") { editable } }')
  end

  class << self
    def now = Process.clock_gettime(CLOCK, :nanosecond) / 1000.0
    def readers = Thread.current.thread_variable_get(:hallmark_bench_readers) || 0.0

    def readers=(value)
      Thread.current.thread_variable_set(:hallmark_bench_readers, value)
    end

    def run
      scenarios = build_scenarios
      bare = scenarios.map { |scenario| [time_bare(scenario.call), allocations(scenario.call)] }
      Hallmark::Collectors::Facts.prepend(ReaderClock)
      Dir.mktmpdir("hallmark-bench") do |dir|
        store = Hallmark::StampStore.new(dir, run: "bench")
        results = scenarios.zip(bare).map do |scenario, (bare_times, bare_allocs)|
          mapping = Shop.map(Hallmark::Mapping.new, current_tenant: scenario.current_tenant)
          Hallmark::Collectors.install!(mapping: mapping, store: store)
          measure_installed(scenario, bare_times, bare_allocs)
        end
        Hallmark::Collectors.uninstall!
        print_results(results, dir)
      end
    end

    private

    def build_scenarios
      seller = Shop::User.new("sam")
      member = Shop::User.new("ann")
      Shop.memberships[[member, seller]] = ["admin"]
      link = Shop::Link.new(seller)
      GraphqlShop.links["1"] = link
      context = PunditShop::Context.new(member, seller)
      publisher = PunditShop::ProductPublisher.new(member, seller)
      session = Shop::Session.new(member, seller, link)
      # Four links for the list scopes, which read the facts of three.
      Shop.links.replace(Array.new(4) { Shop::Link.new(seller) })
      [
        Scenario.new("Pundit rule called directly", -> { PunditShop::LinkPolicy.new(context, link).edit? }, :seller),
        Scenario.new("Pundit authorize (no request)", -> { publisher.publish(link, :update?) }, :seller),
        Scenario.new("Action Policy apply",
                     -> { ApShop::LinkPolicy.new(link, user: member, seller: seller).apply(:edit?) }, :seller),
        Scenario.new("DeclarativePolicy allowed?", lambda {
          Shop.session = session
          DpShop::LinkPolicy.new(member, link).allowed?(:update_link)
        }, -> { Shop.session&.seller }),
        Scenario.new("Pundit request (controller)", lambda {
          Shop.request(PunditShop::LinksController, :edit, user: member, seller: seller, link: link)
        }, :seller),
        # A list scope (phase 3 step 7): the call and three of the four
        # records it lists, read when the action loads them.
        Scenario.new("Pundit list in a request", lambda {
          Shop.request(PunditShop::LinksController, :catalog, user: member, seller: seller)
        }, :seller),
        Scenario.new("Action Policy scope", lambda {
          ApShop::LinkPolicy.new(nil, user: member, seller: seller)
                            .apply_scope(Shop::Relation.new(Shop.links), type: :shop_relation).to_a
        }, :seller),
        # As a GitLab page makes many DeclarativePolicy checks per request;
        # the row is per request, so divide by 5 for one decision.
        Scenario.new("5 DeclarativePolicy in a request", lambda {
          Shop.session = session
          Hallmark::Collectors.within_entry_point("BenchController#show") do
            5.times { DpShop::LinkPolicy.new(member, link).allowed?(:update_link) }
          end
        }, -> { Shop.session&.seller }),
        graphql_scenario("GraphQL query, no decision", Api::QUIET, 31, session),
        graphql_scenario("GraphQL query, 2 decisions", Api::DECIDING, 33, session)
      ]
    end

    def graphql_scenario(name, document, fields, session)
      context = { current_user: session.user, current_seller: session.seller }
      Scenario.new(name, lambda {
        Shop.session = session
        Api::Schema.execute(document: document, context: context)
      }, -> { Shop.session&.seller }, fields)
    end

    def time_bare(call)
      WARMUP.times { call.call }
      times = []
      batches { times << timed(call) }
      times
    end

    # Cycles through the states each iteration; only the `on` state reads facts.
    def measure_installed(scenario, bare_times, bare_allocs)
      call = scenario.call
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
        end
      end
      allocs = STATES.to_h do |state|
        switch(state)
        [state, allocations(call)]
      end
      switch(:on)
      Result.new(scenario.name, times.merge(bare: bare_times), readers, allocs.merge(bare: bare_allocs),
                 scenario.fields)
    end

    # The state the collectors are in, set off the clock. Writes their
    # instance variables directly: the bench toggles them per call, and
    # `install!` and `uninstall!` do far more than that.
    def switch(state)
      Hallmark::Collectors.instance_variable_set(:@active, state != :off)
      Hallmark::Collectors.instance_variable_set(:@sample_rate, state == :skip ? 0.0 : 1.0)
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

    def print_results(results, dir)
      puts "Hallmark #{Hallmark::VERSION}, #{RUBY_DESCRIPTION}"
      puts "#{N} calls per state per scenario; microseconds per call; allocs are objects per call", ""
      titles = ["bare p50", "idle p50", "own p50", "own p99", "read p50", "read p99", "allocs", "skip p50",
                "skip p99", "skip allocs"].map { |title| title.rjust(9) }
      header = ["scenario".ljust(32), *titles].join(" ")
      puts header, "-" * header.size
      results.each { |result| puts row(result) }
      print_per_field(results)
      stamps = Hallmark::StampSet.load(dir).stamps.size
      puts "", "#{stamps} distinct stamps written"
    end

    # What each field of a GraphQL query adds over the bare query, at the
    # median, by state (the `on` row's decisions included).
    def print_per_field(results)
      graphql = results.select(&:fields)
      return if graphql.empty?

      puts "", "GraphQL, microseconds added per field over the bare query (p50):"
      graphql.each do |result|
        bare = percentile(result.times.fetch(:bare), 50)
        added = STATES.map do |state|
          format("%<state>s %<added>.3f", state: state,
                                          added: (percentile(result.times.fetch(state), 50) - bare) / result.fields)
        end
        puts "  #{result.name} (#{result.fields} fields): #{added.join(", ")}"
      end
    end

    def row(result)
      times = result.times
      own = times.fetch(:on).zip(result.readers).map { |time, read| time - read }
      off = times.fetch(:off)
      bare = percentile(times.fetch(:bare), 50)
      values = [bare, percentile(off, 50) - bare,
                percentile(own, 50) - percentile(off, 50), percentile(own, 99) - percentile(off, 99),
                percentile(result.readers, 50), percentile(result.readers, 99),
                result.allocs.fetch(:on) - result.allocs.fetch(:bare),
                percentile(times.fetch(:skip), 50) - percentile(off, 50),
                percentile(times.fetch(:skip), 99) - percentile(off, 99),
                result.allocs.fetch(:skip) - result.allocs.fetch(:bare)]
      [result.name.ljust(32), *values.map { |value| format("%9.2f", value) }].join(" ")
    end
  end
end

HotPath.run
