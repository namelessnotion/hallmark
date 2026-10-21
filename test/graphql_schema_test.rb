# frozen_string_literal: true

require "test_helper"

# A graphql-ruby schema read from source (Extractor::GraphqlSchema), on the
# GraphQL shop example and test/fixtures/apps/graphql_board, a board app
# written the GitLab way (`authorize :ability` on types, DeclarativePolicy
# policies) with Action Policy's field options, interfaces, a union,
# scopes, an EE module and the G4 and G5 hazards; no Java.
class GraphqlSchemaTest < Minitest::Test
  include Hallmark::Guard::DSL

  SHOP = File.join(HallmarkTestHelpers::ROOT, "examples", "graphql_shop")
  BOARD = File.join(HallmarkTestHelpers::FIXTURES, "apps", "graphql_board")

  def member = role(:member, tenant: :record) | role(:admin, tenant: :record)

  def shop_mapping
    mapping = Hallmark::Mapping.new
    mapping.instance_eval do
      tenant "Organization", membership: "Membership", member: :user, roles: :role
      resource "Organization", tenant: :itself
      resource "Project", tenant: :organization
      resource "Invoice", tenant: :organization
      resource "User", kind: :profile
      term "user.member_of?(record)", role(:member, tenant: :record) | role(:admin, tenant: :record)
      term "user.member_of?(record.organization)", role(:member, tenant: :record) | role(:admin, tenant: :record)
      term "user.admin_of?(record.organization)", role(:admin, tenant: :record)
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

  def shop(root = SHOP) = Hallmark::Extractor.new(shop_mapping, root).graphql
  def board = Hallmark::Extractor.new(board_mapping, BOARD).graphql
  def field(schema, type, name) = schema.fields(type).find { |found| found.name == name }

  def test_finds_the_schema_and_its_root_types
    schema = shop

    assert_equal "ShopSchema", schema.schema
    assert_equal "Types::QueryType", schema.root(:query)
    assert_equal "Types::MutationType", schema.root(:mutation)
  end

  # A type backs the resource its class names without Types:: and Type;
  # its GraphQL name is graphql_name, else the class's last part.
  def test_types_back_the_resource_their_class_names
    schema = board

    assert_equal "Card", schema.type("Types::CardType").resource
    assert_equal "Ticket", schema.type("Types::CardType").graphql_name
    assert_equal "Board", schema.type("Types::BoardType").graphql_name
    assert_nil schema.type("Types::LaneType").resource
    assert_equal :interface, schema.type("Types::SearchableInterface").kind
    assert_equal :union, schema.type("Types::ItemUnion").kind
  end

  def test_graphql_type_names_the_resource_a_type_backs
    mapping = board_mapping
    mapping.graphql_type "Types::LaneType", resource: "Card"

    assert_equal "Card", Hallmark::Extractor.new(mapping, BOARD).graphql.type("Types::LaneType").resource
  end

  # `self.authorized?(object, context)` through the method translator:
  # `super` into graphql-ruby's own check reads as no check, and
  # `context[:current_user]` as the signed-in user.
  def test_reads_type_checks_through_the_method_translator
    schema = shop
    fixed = shop(File.join(SHOP, "fixed"))

    assert_equal member, schema.type("Types::OrganizationType").guard
    assert_equal Hallmark::Guard.new(:none), schema.type("Types::InvoiceType").guard
    assert_equal role(:admin, tenant: :record), fixed.type("Types::InvoiceType").guard
    assert_equal logged_in, fixed.type("Types::UserType").guard
  end

  # GitLab: `authorize :read_board` on the type is the DeclarativePolicy
  # ability on the object, read from app/policies; an ability on a type
  # backing no resource is an opaque leaf.
  def test_reads_gitlab_authorize_as_the_policy_ability
    schema = board

    assert_equal member | role(:admin, tenant: :record), schema.type("Types::BoardType").guard
    assert_equal "authorize :read_lane", schema.type("Types::LaneType").guard.operands[0]
    assert_predicate schema.type("Types::LaneType").guard, :opaque?
  end

  def test_reads_field_checks
    schema = board

    assert_equal role(:admin, tenant: :record), field(schema, "Types::BoardType", "owner_name").guard
    assert_equal logged_in, field(schema, "Types::BoardType", "secret").guard
    assert_equal Hallmark::Guard.new(:owner), field(shop(File.join(SHOP, "fixed")), "Types::UserType", "email").guard
  end

  # Action Policy's `authorize: true` checks `show?` on each object the
  # field returns, through that resource's policy.
  def test_reads_action_policy_authorize_on_what_a_field_returns
    schema = board
    pinned = field(schema, "Types::BoardType", "pinned")

    assert_equal Hallmark::Guard.new(:none), pinned.guard
    assert_equal member, schema.child_guard(pinned, "Types::CardType")
  end

  # `[T]`, `T.connection_type`, a resolver's `type`, an interface's
  # implementers and a union's members; arguments from the field's block
  # and from the resolver, its prepended modules included.
  def test_reads_what_fields_return
    schema = board
    cards = field(schema, "Types::BoardType", "cards")

    assert_equal [["Types::CardType"], true, true], [cards.targets, cards.list, cards.connection]
    assert_equal ["Types::BoardType"], field(schema, "Types::QueryType", "board").targets
    assert_equal ["fullPath"], field(schema, "Types::QueryType", "board").arguments
    assert_equal %w[Types::BoardType Types::CardType], field(schema, "Types::QueryType", "searchable").targets
    assert_equal "ItemUnion", field(schema, "Types::QueryType", "item").via
    assert_equal %w[Types::ProjectType Types::UserType], field(shop, "Types::QueryType", "node").targets
  end

  # Fields come from the type, its interfaces and EE modules prepended with
  # prepend_mod_with, in GraphQL names unless `camelize: false`.
  def test_reads_fields_from_interfaces_and_ee_modules
    names = board.fields("Types::BoardType").map(&:graphql_name)

    assert_includes names, "title"
    assert_includes names, "insights"
    assert_includes names, "ownerName"
  end

  # `items.where(board: context[:current_board])` through the term table,
  # with `reauthorize_scoped_objects(false)`.
  def test_reads_scope_items_as_a_guard_on_list_members
    card = board.type("Types::CardType")

    assert_equal in_current_tenant, card.scope
    refute card.reauthorize
    assert_predicate board.type("Types::NoteType").scope, :opaque?
  end

  def test_lints_mutations_checked_late_or_not_at_all
    found = board.lints.select { |lint| lint.kind == "G4" }.map(&:message)

    assert_equal 3, found.size
    assert(found.any? { |message| message.start_with?("Mutations::MoveCard has no `ready?`") })
    assert(found.any? { |message| message.include?("MoveCard#load_card loads `card_id` without `super`") })
    assert(found.any? { |message| message.include?("ArchiveBoard is mounted with Action Policy's `authorize:`") })
    refute(found.any? { |message| message.include?("RenameBoard") })
  end

  def test_lints_scopes_switched_off
    found = board.lints.select { |lint| lint.kind == "G5" }

    assert_equal ["app/graphql/types/board_type.rb:10", "app/graphql/types/note_type.rb:5"], found.map(&:location)
    assert_includes found.first.message, "sets `scope: false`"
  end

  def test_the_fixed_shop_has_no_lint
    assert_empty shop(File.join(SHOP, "fixed")).lints
    assert_equal ["G4"], shop.lints.map(&:kind)
  end

  def test_camelizes_as_graphql_ruby_does
    assert_equal "amountCents", Hallmark::Extractor::GraphqlSchema.camelize("amount_cents")
    assert_equal "name", Hallmark::Extractor::GraphqlSchema.camelize("name")
    assert_equal "_privateField", Hallmark::Extractor::GraphqlSchema.camelize("_private_field")
  end
end
