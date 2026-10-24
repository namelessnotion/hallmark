# frozen_string_literal: true

# Measures what the collectors add to one authorization decision (docs/PLAN.md,
# "Phase 3 plan", step 1). Each scenario runs a rule on the test shop
# (test/support/shop.rb), first with Hallmark not installed (bare), then with
# the collectors installed, cycling through the states and printing the
# columns `bench/measure.rb` describes.
#
# The GraphQL rows are one query each (31 fields, then 33 with two
# decisions); below the table, what each field adds over the bare query,
# with the tracer on, not sampled and off.
#
#   bundle exec rake bench
#   BENCH_N=50000 bundle exec ruby -Ilib -Itest bench/hot_path.rb

require "hallmark"
require "tmpdir"
require "support/shop"
require "support/graphql_shop"
require_relative "measure"

# The benchmark: scenarios, measurement and the table it prints.
module HotPath
  # One rule call, and the shop mapping's current tenant for it (DeclarativePolicy
  # policies have no `seller`, so its scenarios read the session's); a
  # GraphQL query also gives the number of fields it resolves, and a
  # revocation row the noted pairs the collectors check allows against.
  Scenario = Struct.new(:name, :call, :current_tenant, :fields, :revoked)

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
    def run
      scenarios = build_scenarios
      bare = scenarios.map { |scenario| [time_bare(scenario.call), allocations(scenario.call)] }
      Hallmark::Collectors::Facts.prepend(ReaderClock)
      Dir.mktmpdir("hallmark-bench") do |dir|
        store = Hallmark::StampStore.new(dir, run: "bench")
        results = scenarios.zip(bare).map do |scenario, (bare_times, bare_allocs)|
          mapping = Shop.map(Hallmark::Mapping.new, current_tenant: scenario.current_tenant)
          Hallmark::Collectors.install!(mapping: mapping, store: store)
          Hallmark::Collectors.facts&.revoked = scenario.revoked&.call
          measure_installed(scenario.name, scenario.call, bare_times, bare_allocs, fields: scenario.fields)
        end
        Hallmark::Collectors.uninstall!
        print_results(results, dir)
      end
    end

    private

    def build_scenarios
      seller = Shop::User.new("sam")
      member = Shop::User.new("ann")
      # Ids, so the revocation rows can name the user and the seller.
      { seller => 1, member => 2 }.each { |user, id| user.define_singleton_method(:id) { id } }
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
        *revocation_scenarios(member, seller, link),
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

    # The Pundit request with no revocation noted, then with one for the
    # deciding user in the current seller.
    def revocation_scenarios(member, seller, link)
      require "hallmark/collectors/revocations"
      noted = Hallmark::Collectors::Revocations
      request = -> { Shop.request(PunditShop::LinksController, :edit, user: member, seller: seller, link: link) }
      revoked = lambda do
        pairs = noted::Noted.new
        pairs.update(noted.ref(member), noted.ref(seller), removed: ["marketing"], held: [])
        pairs
      end
      [Scenario.new("Pundit request, revocations, none", request, :seller, nil, -> { noted::Noted.new }),
       Scenario.new("Pundit request, revocation noted", request, :seller, nil, revoked)]
    end

    def graphql_scenario(name, document, fields, session)
      context = { current_user: session.user, current_seller: session.seller }
      Scenario.new(name, lambda {
        Shop.session = session
        Api::Schema.execute(document: document, context: context)
      }, -> { Shop.session&.seller }, fields)
    end

    def print_results(results, dir)
      puts "Hallmark #{Hallmark::VERSION}, #{RUBY_DESCRIPTION}"
      puts "#{N} calls per state per scenario; microseconds per call; allocs are objects per call", ""
      title = header
      puts title, "-" * title.size
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
  end
end

HotPath.run
