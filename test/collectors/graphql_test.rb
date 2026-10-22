# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "rack/mock"
require "support/fixture_solver"
require "support/graphql_shop"
require_relative "shop_people"

# The graphql-ruby hook names each decision after the field being resolved
# and stamps types' own `authorized?` checks.
class GraphqlCollectorTest < Minitest::Test
  include ShopPeople

  Hook = Hallmark::Collectors::GraphqlHook

  def setup
    super
    GraphqlShop.links.replace("1" => @ann_link, "2" => @bob_link)
    GraphqlShop.sellers.replace("ann" => @ann, "bob" => @bob)
  end

  # DeclarativePolicy rules read the current seller from the session; type
  # checks read the query's context (`graphql`).
  def collect_graphql(sample_rate: 1.0, &)
    collect(current_tenant: -> { Shop.session&.seller }, sample_rate: sample_rate, map: lambda {
      graphql current_user: ->(ctx) { ctx[:current_user] }, current_tenant: ->(ctx) { ctx[:current_seller] }
    }, &)
  end

  # Runs a query as `user` acting for `seller`, outside any controller.
  def query_as(query, user:, seller: nil, schema: GraphqlShop::Schema, **context)
    Shop.session = Shop::Session.new(user, seller, nil)
    schema.execute(query, context: { current_user: user, current_seller: seller, **context }).to_h
  ensure
    Shop.session = nil
  end

  def entry_points(set) = set.stamps.map { |stamp| [stamp.entry_point, stamp.policy, stamp.rule] }

  def test_names_decisions_after_the_field_path
    set = collect_graphql do
      query_as(<<~GRAPHQL, user: @ada, seller: @ann)
        {
          mine: link(id: "1") { editable }
          seller(name: "ann") { links { id } linksConnection { nodes { id } edges { node { editable } } } }
        }
      GRAPHQL
    end

    assert_equal [["Query.link", "GraphqlShop::LinkType", "authorized?"],
                  ["Query.link.editable", "DpShop::LinkPolicy", "update_link"],
                  ["Query.seller", "GraphqlShop::UserType", "authorized?"],
                  ["Query.seller.links", "GraphqlShop::LinkType", "authorized?"],
                  ["Query.seller.linksConnection", "GraphqlShop::LinkType", "authorized?"],
                  ["Query.seller.linksConnection.editable", "DpShop::LinkPolicy", "update_link"]],
                 entry_points(set)
  end

  def test_resolves_aliases_through_fragments
    set = collect_graphql do
      query_as(<<~GRAPHQL, user: @ada, seller: @ann)
        query { s: seller(name: "ann") { ...Items } }
        fragment Items on User { items: links { ... on Link { canEdit: editable } } }
      GRAPHQL
    end

    assert_includes entry_points(set), ["Query.seller.links.editable", "DpShop::LinkPolicy", "update_link"]
  end

  def test_names_a_mutation_and_lazy_resolution
    set = collect_graphql do
      query_as('mutation { linkRename(id: "1") { link { id } } }', user: @ada, seller: @ann)
      query_as('{ lazyLink(id: "1") { id } }', user: @ada, seller: @ann)
    end

    assert_equal [["Mutation.linkRename", "DpShop::LinkPolicy", "update_link"],
                  ["Mutation.linkRename.link", "GraphqlShop::LinkType", "authorized?"],
                  # The rule runs when the lazy value is synced, outside any resolver.
                  ["Query", "DpShop::LinkPolicy", "update_link"],
                  ["Query.lazyLink", "GraphqlShop::LinkType", "authorized?"]],
                 entry_points(set)
  end

  # A type's own scope_items stamps a list under the field's entry point,
  # with the records it kept.
  def test_stamps_a_types_scope_items_as_a_list
    set = collect_graphql do
      query_as('{ seller(name: "ann") { listedLinks { id } } }', user: @ada, seller: @ann)
    end

    lists = set.stamps.select(&:list)
    assert_equal [["Query.seller.listedLinks", "GraphqlShop::ListedLinkType", "scope_items"]],
                 lists.map { |stamp| [stamp.entry_point, stamp.policy, stamp.rule] }.uniq
    assert_equal [true], lists.reject(&:class_level).map(&:in_current_tenant)
  end

  def test_stamps_a_type_check_with_the_context_facts
    set = collect_graphql do
      assert_equal({ "data" => { "link" => { "id" => "1" } } },
                   query_as('{ link(id: "1") { id } }', user: @ada, seller: @ann))
      # A stranger's check fails, and graphql-ruby shows nil in place of the link.
      assert_equal({ "data" => { "link" => nil } }, query_as('{ link(id: "1") { id } }', user: @sam, seller: @sam))
    end

    allow = stamp_for(set, "Query.link", "authorized?", decision: "allow")
    assert_equal ["GraphqlShop::LinkType", "Shop::Link", true, true, ["admin"], true, ["admin"]],
                 allow.to_h.values_at(:policy, :resource, :enforced, :logged_in, :record_roles, :in_current_tenant,
                                      :current_roles)
    deny = stamp_for(set, "Query.link", "authorized?", decision: "deny")
    assert_equal [[], false, ["owner"]], deny.to_h.values_at(:record_roles, :in_current_tenant, :current_roles)
  end

  def test_an_exception_in_a_type_check_is_a_deny
    set = collect_graphql do
      assert_raises(KeyError) { query_as('{ link(id: "1") { id } }', user: @ada, seller: @ann, explode: true) }
    end

    assert_equal %w[deny KeyError], stamp_for(set, "Query.link", "authorized?").to_h.values_at(:decision, :raised)
  end

  # ProductType's check only asks a DeclarativePolicy rule, which its own
  # hook stamps with the field's entry point; the type check is not stamped
  # a second time.
  def test_a_type_check_that_asks_a_library_is_stamped_once
    set = collect_graphql do
      query_as('{ product(id: "1") { id } }', user: @ada, seller: @ann)
      query_as('{ product(id: "2") { id } }', user: @ada, seller: @ann)
    end

    assert_equal [["Query.product", "GraphqlShop::ProductPolicy", "read_product"]], entry_points(set).uniq
    assert_equal %w[allow deny], set.stamps.map(&:decision)
  end

  def test_not_sampled_stamps_nothing_and_builds_no_name
    flunk_on_call = ->(*) { flunk "built for a query that is not sampled" }
    set = Hook::Registry.stub(:new, flunk_on_call) do
      Hook::Scope.stub(:new, flunk_on_call) do
        collect_graphql(sample_rate: 0.0) do
          query_as('{ link(id: "1") { editable } product(id: "1") { id } }', user: @ada, seller: @ann)
        end
      end
    end

    assert_empty set.stamps
  end

  def test_a_query_served_by_a_controller_runs_inside_its_request
    set = collect_graphql do
      GraphqlShop::GraphqlController.query = '{ link(id: "1") { editable } }'
      status = Shop.request(GraphqlShop::GraphqlController, :execute, user: @ada, seller: @ann, verb: "POST")

      assert_equal 200, status
    ensure
      GraphqlShop::GraphqlController.query = nil
    end

    assert_equal %w[Query.link Query.link.editable], set.stamps.map(&:entry_point)
    # The checks made in the query count for the controller's request.
    assert_empty set.unchecked
  end

  def test_records_a_context_whose_current_tenant_is_not_the_controllers
    set = collect(current_tenant: -> { Shop.session&.seller }, map: lambda {
      current_tenant(-> { Shop.session&.seller }, controller: :current_seller)
      graphql current_tenant: ->(ctx) { ctx[:current_seller] }
    }) do
      GraphqlShop::GraphqlController.query = '{ link(id: "1") { id } }'
      Shop.request(GraphqlShop::GraphqlController, :execute, user: @ada, seller: @ann, verb: "POST")
      GraphqlShop::GraphqlController.context_seller = @bob
      Shop.request(GraphqlShop::GraphqlController, :execute, user: @ada, seller: @ann, verb: "POST")
    ensure
      GraphqlShop::GraphqlController.query = nil
      GraphqlShop::GraphqlController.context_seller = nil
    end

    mismatch = Hallmark::ContextMismatch.new(entry_point: "GraphqlShop::GraphqlController#execute", operation: "Query",
                                             controller_tenant: "Shop::User", graphql_tenant: "Shop::User")
    assert_equal [mismatch], set.mismatches
    assert_equal "GraphqlShop::GraphqlController#execute (Query): the controller's current tenant is Shop::User, " \
                 "the GraphQL context's Shop::User (another record)", mismatch.to_s
  end

  def test_a_report_lists_mismatches_under_coverage
    mismatch = Hallmark::ContextMismatch.new(entry_point: "GraphqlController#execute", operation: "Query",
                                             controller_tenant: "Group", graphql_tenant: nil)
    analysis = Hallmark::Analysis.build("GraphQL") do
      map { resource "Link" }
      stamps Hallmark::StampSet.parse([mismatch.to_json_line])
    end
    report = analysis.run(solver: FixtureSolver.new)

    assert_equal [mismatch], analysis.inference.coverage.mismatches
    assert_includes report.to_s, "GraphQL requests whose context names another current tenant than the " \
                                 "controller's (G6):\n    GraphqlController#execute (Query): the controller's " \
                                 "current tenant is Group, the GraphQL context's none"
  end

  def test_traces_the_1x_tracer_through_graphql_ruby
    set = collect_graphql do
      query_as('{ mine: link(id: "1") { editable } }', user: @ada, seller: @ann, schema: GraphqlShop::LegacySchema)
      query_as('{ lazyLink(id: "1") { id } }', user: @ada, seller: @ann, schema: GraphqlShop::LegacySchema)
    end

    assert_equal [["Query.link", "GraphqlShop::LinkType", "authorized?"],
                  ["Query.link.editable", "DpShop::LinkPolicy", "update_link"],
                  ["Query", "DpShop::LinkPolicy", "update_link"],
                  ["Query.lazyLink", "GraphqlShop::LinkType", "authorized?"]],
                 entry_points(set)
    # Given the legacy tracer, the schema gets no trace module as well.
    refute_includes GraphqlShop::LegacySchema.trace_modules_for(:default), Hook::Trace
  end

  # graphql-ruby 1.x (GitLab at 7ce3a7d runs 1.13) has only `tracer`: a
  # schema that cannot `trace_with` gets the tracer once, and the events
  # 1.x sends, replayed by hand, name the decisions.
  def test_gives_a_1x_schema_the_tracer_once
    schema = Class.new(GraphQL::Schema) do
      singleton_class.undef_method(:trace_with)
      def self.tracers = @tracers ||= []
      def self.tracer(tracer, **) = tracers << tracer
    end
    2.times { Hook.attach(schema) }

    assert_equal [Hook::LegacyTracer], schema.tracers
  end

  def test_replays_the_1x_events
    query = GraphQL::Query.new(GraphqlShop::Schema, '{ mine: link(id: "1") { canEdit: editable } }',
                               context: { current_user: @ada, current_seller: @ann })
    multiplex = Struct.new(:queries).new([query])
    tracer = Hook::LegacyTracer
    set = collect_graphql do
      Shop.session = Shop::Session.new(@ada, @ann, nil)
      tracer.trace("execute_multiplex", { multiplex: multiplex }) do
        tracer.trace("execute_query", { query: query }) do
          tracer.trace("execute_field", { query: query, path: ["mine"] }) { @ann_link }
          tracer.trace("authorized", { context: query.context, type: GraphqlShop::LinkType, object: @ann_link,
                                       path: ["mine"] }) do
            GraphqlShop::LinkType.authorized?(@ann_link, query.context)
          end
          tracer.trace("execute_field", { query: query, path: %w[mine canEdit] }) do
            DpShop::LinkPolicy.new(@ada, @ann_link).allowed?(:update_link)
          end
        end
        tracer.trace("execute_query_lazy", { query: nil, multiplex: multiplex }) do
          DpShop::LinkPolicy.new(@ada, @bob_link).allowed?(:update_link)
        end
      end
    ensure
      Shop.session = nil
    end

    assert_equal [["Query.link", "GraphqlShop::LinkType", "authorized?"],
                  ["Query.link.editable", "DpShop::LinkPolicy", "update_link"],
                  ["Query", "DpShop::LinkPolicy", "update_link"]],
                 entry_points(set)
  end

  def test_traces_a_schema_defined_after_install_once
    set = collect_graphql do
      load File.expand_path("../support/late_graphql_schema.rb", __dir__)
      # Reopened, and attached again by hand: still one trace module.
      load File.expand_path("../support/late_graphql_schema.rb", __dir__)
      Hook.attach(GraphqlShop::LateSchema)
      query_as('{ link(id: "1") { id } }', user: @ada, seller: @ann, schema: GraphqlShop::LateSchema)
    end

    assert_equal 1, GraphqlShop::LateSchema.trace_modules_for(:default).count(Hook::Trace)
    assert_equal [["Query.link", "GraphqlShop::LinkType", "authorized?"]], entry_points(set)
  ensure
    GraphqlShop.send(:remove_const, :LateSchema) if GraphqlShop.const_defined?(:LateSchema, false)
  end

  def test_keeps_a_root_node_lookup_and_drops_wrappers_below_it
    scope = Hook::Scope.new(GraphQL::Query.new(GraphqlShop::Schema,
                                               '{ seller(name: "ann") { linksConnection { edges { node { id } } } } }'))

    assert_equal "Query.seller.linksConnection.id", scope.path_name(%w[seller linksConnection edges node id])
    assert_equal "Query.node", scope.path_name(%w[node])
  end
end
