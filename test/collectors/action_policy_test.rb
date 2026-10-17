# frozen_string_literal: true

require "test_helper"
require_relative "shop_people"

class ActionPolicyCollectorTest < Minitest::Test
  include ShopPeople

  EDIT = "ApShop::LinksController#edit"
  UPDATE = "ApShop::LinksController#update"

  def test_stamps_an_allow_with_the_facts_that_held
    set = collect { assert_equal 200, Shop.request(ApShop::LinksController, :edit, user: @ann, seller: @ann, link: @ann_link) }

    stamp = stamp_for(set, EDIT, "edit?")
    assert_equal ["ApShop::LinkPolicy", "Shop::Link", "allow", true, false],
                 stamp.to_h.values_at(:policy, :resource, :decision, :enforced, :class_level)
    assert_equal [true, true, true, true], stamp.to_h.values_at(:logged_in, :member, :in_current_tenant, :granted)
    assert_equal [["owner"], ["owner"], []], stamp.to_h.values_at(:record_roles, :current_roles, :roles)
  end

  # M2: an admin of the current seller updates another seller's link
  def test_stamps_current_tenant_confusion_as_it_happened
    set = collect { Shop.request(ApShop::LinksController, :update, user: @ada, seller: @ann, link: @bob_link) }

    stamp = stamp_for(set, UPDATE, "update?")
    assert_equal "allow", stamp.decision
    assert_equal [false, false, false], stamp.to_h.values_at(:member, :in_current_tenant, :granted)
    assert_equal [[], ["admin"]], stamp.to_h.values_at(:record_roles, :current_roles)
  end

  def test_tells_enforcing_authorize_from_queries
    set = collect { Shop.request(ApShop::LinksController, :update, user: @ada, seller: @ann, link: @ann_link) }

    assert stamp_for(set, UPDATE, "update?").enforced
    query = stamp_for(set, UPDATE, "edit?")
    refute query.enforced
    assert_equal "allow", query.decision
  end

  def test_stamps_denies_and_anonymous_visitors
    set = collect do
      assert_equal 403, Shop.request(ApShop::LinksController, :edit, user: @sam, seller: @ann, link: @ann_link)
      assert_equal 403, Shop.request(ApShop::LinksController, :edit, link: @ann_link)
    end

    assert_equal "deny", stamp_for(set, EDIT, "edit?", logged_in: true).decision
    anonymous = stamp_for(set, EDIT, "edit?", logged_in: false)
    assert_equal "deny", anonymous.decision
    assert_nil anonymous.current_roles
    assert_equal [false, nil], anonymous.to_h.values_at(:member, :in_current_tenant)
  end

  def test_an_exception_inside_a_rule_is_a_deny
    set = collect do
      assert_raises(KeyError) do
        Shop.request(ApShop::LinksController, :destroy, user: @ada, seller: @ann, link: @ann_link)
      end
    end

    stamp = stamp_for(set, "ApShop::LinksController#destroy", "destroy?")
    assert_equal %w[deny KeyError], stamp.to_h.values_at(:decision, :raised)
  end

  def test_policy_specs_stamp_rules_without_an_entry_point
    set = collect do
      policy = ApShop::LinkPolicy.new(@bob_link, user: @mia, seller: @ann)
      refute policy.apply(:edit?)
    end

    stamp = set.stamps.fetch(0)
    assert_nil stamp.entry_point
    refute stamp.enforced
    assert_equal ["marketing"], stamp.current_roles
  end

  # A headless policy: `authorize! :dashboard` checks a Symbol, not a record.
  def test_a_headless_policy_is_class_level
    set = collect do
      assert_equal 200, Shop.request(ApShop::DashboardsController, :show, user: @sue)
      assert_equal 403, Shop.request(ApShop::DashboardsController, :show, user: @ann, seller: @ann)
    end

    show = "ApShop::DashboardsController#show"
    allow = stamp_for(set, show, "show?", decision: "allow")
    assert_equal ["ApShop::DashboardPolicy", "dashboard", true, true],
                 allow.to_h.values_at(:policy, :resource, :class_level, :enforced)
    assert stamp_for(set, show, "show?", decision: "deny", class_level: true, resource: "dashboard")
  end

  def test_equal_decisions_collapse_into_one_stamp
    set = collect do
      3.times { Shop.request(ApShop::LinksController, :edit, user: @ann, seller: @ann, link: @ann_link) }
    end

    assert_equal 1, set.stamps.size
  end

  def test_records_nothing_when_uninstalled
    Dir.mktmpdir do |dir|
      store = Hallmark::StampStore.new(dir, run: "test")
      Hallmark::Collectors.install!(mapping: Shop.map(Hallmark::Mapping.new), store: store)
      Hallmark::Collectors.uninstall!
      Shop.request(ApShop::LinksController, :edit, user: @ann, seller: @ann, link: @ann_link)
      store.flush

      assert_empty Dir.children(dir)
    end
  end
end
