# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require_relative "shop_people"

# List scopes (phase 3 step 7): Pundit's `Scope#resolve` and Action
# Policy's scopes stamp the call and the records the app loads.
class ListCollectorTest < Minitest::Test
  include ShopPeople

  CATALOG = "PunditShop::LinksController#catalog"

  def setup
    super
    Shop.links.replace([@ann_link, @bob_link])
    # Ada works for both sellers, so her list spans both.
    Shop.memberships[[@ada, @bob]] = ["admin"]
  end

  def teardown
    Shop.links.clear
    super
  end

  def test_pundit_stamps_the_call_and_the_records_loaded
    set = collect { Shop.request(PunditShop::LinksController, :catalog, user: @ada, seller: @ann) }

    lists = set.stamps.select(&:list)
    call = lists.find(&:class_level)
    assert_equal ["PunditShop::LinkPolicy", "Scope#resolve", "Shop::Link", CATALOG],
                 call.to_h.values_at(:policy, :rule, :resource, :entry_point)
    records = lists.reject(&:class_level)
    assert_equal [true, true], records.map(&:allow?)
    assert_equal [false, true], records.map(&:in_current_tenant).sort_by(&:to_s)
  end

  # A list never ties a rule to an entry point, and it checks the request.
  def test_list_stamps_enforce_nothing_and_check_the_request
    set = collect { Shop.request(PunditShop::LinksController, :catalog, user: @ada, seller: @ann) }

    assert_equal [false], set.stamps.map(&:enforced).uniq
    assert_empty set.unchecked
  end

  # The scope keeps its user in a private reader, as Pundit's generator writes it.
  def test_reads_private_readers_on_the_scope
    set = collect { Shop.request(PunditShop::LinksController, :catalog, user: @mia, seller: @ann) }

    record = set.stamps.find { |stamp| stamp.list && !stamp.class_level }
    assert_equal ["marketing"], record.record_roles
  end

  def test_reads_no_record_the_app_did_not_load
    loads = Shop::Relation.loads
    set = collect { Shop.request(PunditShop::LinksController, :tally, user: @ada, seller: @ann) }

    assert_equal loads, Shop::Relation.loads
    assert_equal [true], set.stamps.select(&:list).map(&:class_level)
    assert_empty set.unchecked
  end

  def test_a_list_not_sampled_still_checks_the_request
    set = collect(sample_rate: 0.0) { Shop.request(PunditShop::LinksController, :catalog, user: @ada, seller: @ann) }

    assert_empty set.stamps
    assert_empty set.unchecked
  end

  def test_reads_at_most_a_few_records
    Shop.links.replace(Array.new(6) { Shop::Link.new(@ann) })
    calls = 0
    count = ->(**) { calls += 1 }
    collect do
      Hallmark::Collectors.stub(:decision, count) do
        Shop.request(PunditShop::LinksController, :catalog, user: @ada, seller: @ann)
      end
    end

    assert_equal Hallmark::ListScope::RECORDS_READ, calls
  end

  def test_a_scope_resolved_in_a_spec_has_no_entry_point
    set = collect do
      context = PunditShop::Context.new(@ada, @ann)
      PunditShop::LinkPolicy::Scope.new(context, Shop::Relation.new(Shop.links)).resolve.to_a
    end

    assert(set.stamps.select(&:list).all? { |stamp| stamp.entry_point.nil? })
    assert_equal 3, set.stamps.count(&:list)
  end

  def test_action_policy_names_the_scope_after_its_declaration
    set = collect { Shop.request(ApShop::LinksController, :index, user: @ada, seller: @ann) }

    lists = set.stamps.select(&:list)
    assert_equal ["scope_for(:shop_relation)"], lists.map(&:rule).uniq
    assert_equal ["ApShop::LinkPolicy"], lists.map(&:policy).uniq
    records = lists.reject(&:class_level)
    assert_equal [true], records.map(&:in_current_tenant)
    assert_equal ["ApShop::LinksController#index"], lists.map(&:entry_point).uniq
  end

  def test_names_action_policy_scopes
    assert_equal "relation_scope", Hallmark::ListScope.action_policy_rule(:active_record_relation, :default)
    assert_equal "relation_scope(:own)", Hallmark::ListScope.action_policy_rule("active_record_relation", :own)
    assert_equal "scope_for(:data, :own)", Hallmark::ListScope.action_policy_rule(:data, :own)
  end

  def test_list_stamps_read_back_and_other_lines_are_unchanged
    stamp = Hallmark::Stamp.new(policy: "P", rule: "r?", decision: "allow")
    refute_includes stamp.to_json_line, "list"
    listed = Hallmark::Stamp.new(policy: "P", rule: "Scope#resolve", decision: "allow", list: true)
    assert Hallmark::StampSet.parse([listed.to_json_line]).stamps.first.list
  end
end
