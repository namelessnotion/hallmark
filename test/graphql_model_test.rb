# frozen_string_literal: true

require "test_helper"

# The GraphQL reachability model (GraphqlModel) as Alloy and as Ruby: which
# edges it keeps, collapses or leaves out, the facts and functions it
# renders, its checks, and the witness paths it rebuilds from an
# instance; no Java.
class GraphqlModelTest < Minitest::Test
  include Hallmark::Guard::DSL

  SHOP = File.join(HallmarkTestHelpers::ROOT, "examples", "graphql_shop")
  BOARD = File.join(HallmarkTestHelpers::FIXTURES, "apps", "graphql_board")

  # `member` is what the organization's check reads as.
  def shop_mapping(tenancy: true, member: logged_in)
    mapping = Hallmark::Mapping.new
    mapping.instance_eval do
      if tenancy
        tenant "Organization", membership: "Membership", member: :user, roles: :role
        resource "Organization", tenant: :itself
        resource "Project", tenant: :organization
        resource "Invoice", tenant: :organization
      else
        resource "Organization"
        resource "Project"
        resource "Invoice"
      end
      resource "User", kind: :profile
      field_policy "User", :email, owner
      term "user.member_of?(record)", member
      term "user.member_of?(record.organization)", logged_in
    end
    mapping
  end

  def board_mapping
    mapping = Hallmark::Mapping.new
    mapping.instance_eval do
      tenant "Board", membership: "Membership", member: :user, roles: :role
      current_tenant :current_board
      resource "Board", tenant: :itself
      resource "Card", tenant: :board
      resource "Note", tenant: :board
      term "member", role(:member, tenant: :record) | role(:admin, tenant: :record)
      term "admin", role(:admin, tenant: :record)
      term "user.member_of?(record.board)", role(:member, tenant: :record) | role(:admin, tenant: :record)
    end
    mapping
  end

  def model(mapping = shop_mapping, root = SHOP) = Hallmark::Extractor.new(mapping, root).graphql&.model || flunk

  def test_checks_each_mapped_type_reached_and_each_field_with_a_policy
    checks = model.checks

    assert_equal %w[reach_Invoice reach_Organization reach_Project reach_User reach_User_email],
                 checks.map(&:check_name)
    assert_equal ["GraphQL User.email", "User.email"], [checks.last.action, checks.last.target]
    assert_equal ["Types::UserType#authorized?"], checks.last.rules
    assert_equal ["app/graphql/types/user_type.rb:10"], checks.last.locations
  end

  # A path through BillingType, which backs no resource and checks
  # nothing, is one relation on Project; a child lives in its parent's
  # tenant; node and nodes enter the same way, so one root predicate each.
  def test_renders_relations_tenant_facts_and_reachability
    shop = model
    source = shop.source(true)

    assert_equal ["gql_Project_owner: set UserProfile", "gql_Project_billing_invoices: set Invoice"],
                 shop.relations_of("Project")
    assert_includes source, "fact gql_Project_billing_invoices_same_tenant { all a: Project, " \
                            "b: a.gql_Project_billing_invoices | b.tenant = a.tenant }"
    assert_includes source, "fun gqlReach_Invoice[p: Principal, cur: Tenant, o: Resource]: set Invoice " \
                            "{ (o & gqlRoots_Invoice[p, cur]) + o.*(gqlStep[p, cur]).(gqlInto_Invoice[p, cur]) }"
    assert_equal 3, shop.roots.size
    assert_equal ["Project.billing.invoices (through Billing)"],
                 shop.notes.fetch("GraphQL fields through types that back no mapped resource, modeled as one edge")
  end

  def test_a_model_without_tenants_has_no_current_tenant
    shop = model(shop_mapping(tenancy: false))
    source = shop.source(false)

    refute_includes source, "cur"
    refute_includes source, "same_tenant"
    assert_equal "p: Principal, o: gqlRoots[p], r: gqlReach_Invoice[p, o]", shop.quantifier(shop.checks.first, false)
  end

  def test_crosses_tenants_drops_the_same_tenant_fact
    mapping = shop_mapping
    mapping.graphql_type "Types::InvoiceType", crosses_tenants: true

    refute_includes model(mapping).source(true), "gql_Project_billing_invoices_same_tenant"
  end

  # LaneType backs no resource and checks `authorize :read_lane`, which
  # Hallmark cannot model, so the path through it is left out and listed.
  def test_leaves_out_paths_through_checks_it_cannot_model
    board = model(board_mapping, BOARD)

    assert_empty(board.edges.select { |edge| edge.path == "lanes.cards" })
    assert_equal ["Board.lanes.cards (through Lane): Types::LaneType.authorized?: opaque(`authorize :read_lane`)"],
                 board.notes.fetch("GraphQL fields not modeled (a check on the way could not be read; the model " \
                                   "assumes it denies)")
  end

  # A scoped list's members must pass the type's scope; with
  # `reauthorize_scoped_objects(false)` its `authorized?` is skipped.
  def test_scoped_lists_check_the_scope
    board = model(board_mapping, BOARD)
    cards = board.edges.find { |edge| edge.relation == "gql_Board_cards" } || flunk

    assert_equal in_current_tenant, cards.entry
    assert_includes board.source(true),
                    "pred gqlIn_gql_Board_cards[p: Principal, cur: Tenant, r: Card] { r.tenant = cur }"
  end

  # The witness path, rebuilt from relation tuples: breadth first from the
  # root object `o` to `r`, in GraphQL names.
  def test_rebuilds_the_query_that_reaches_a_witness
    shop = model
    check = shop.checks.first
    instance = Hallmark::Receipt::Instance.new(
      { "gql_Project_billing_invoices" => [["Project$0", "Invoice$1"]], "gql_Organization_projects" => [] },
      { "$reach_Invoice_p" => [["catalog/User$0"]], "$reach_Invoice_o" => [["Project$0"]],
        "$reach_Invoice_r" => [["Invoice$1"]] }
    )

    assert_equal "query { node(id: ...) { ... on Project { billing { invoices { ... } } } } }",
                 check.path(instance)
  end

  def test_digest_covers_the_whole_graphql_section
    mapping = shop_mapping
    check = model(mapping).checks.first
    other = shop_mapping
    other.graphql_type "Types::InvoiceType", crosses_tenants: true

    assert_equal check.digest(mapping), model(mapping).checks.first.digest(mapping)
    refute_equal check.digest(mapping), model(other).checks.first.digest(other)
  end

  # Watch and baselines copy checks into other analyses.
  def test_an_analysis_takes_a_check_with_its_model
    shop = model
    analysis = Hallmark::Analysis.new("copy", mapping: shop_mapping)
    analysis.add(shop.checks.first)

    assert_same shop, analysis.graphql
    assert_includes Hallmark::ModelBuilder.new(analysis).source, "assert reach_Invoice"
    assert_raises(Hallmark::ConfigurationError) { analysis.add(shop.checks.first) }
  end

  def test_validates_the_guards_it_renders
    mapping = shop_mapping(member: flag(:archived))

    error = assert_raises(Hallmark::ConfigurationError) do
      Hallmark::Analysis.build("shop", mapping: mapping) { graphql_schema SHOP }
    end
    assert_includes error.message, "reads flags Organization does not declare: archived"
  end
end
