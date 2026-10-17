# frozen_string_literal: true

require "test_helper"
require_relative "shop_people"

class DeclarativePolicyCollectorTest < Minitest::Test
  include ShopPeople

  # DeclarativePolicy policies carry no current tenant, so the mapping reads
  # it from the app (a lambda with no arguments).
  def collect_dp(&)
    collect(current_tenant: -> { Shop.session&.seller }, &)
  end

  def test_stamps_each_ability
    set = collect_dp do
      Shop.session = Shop::Session.new(@ada, @ann, nil)
      assert DpShop::LinkPolicy.new(@ada, @ann_link).allowed?(:update_link)
      refute DpShop::LinkPolicy.new(@ada, @bob_link).allowed?(:update_link, :feature_link)
    ensure
      Shop.session = nil
    end

    allow = stamp_for(set, nil, "update_link", decision: "allow")
    assert_equal ["DpShop::LinkPolicy", true, true], allow.to_h.values_at(:policy, :enforced, :in_current_tenant)
    deny = stamp_for(set, nil, "update_link", decision: "deny")
    assert_equal [false, ["admin"]], deny.to_h.values_at(:in_current_tenant, :current_roles)
    # allowed? with two abilities stops at the first that fails, as the library does
    assert_nil stamp_for(set, nil, "feature_link")
  end

  def test_an_exception_inside_a_condition_is_a_deny
    set = collect_dp do
      assert_raises(KeyError) { DpShop::LinkPolicy.new(@ann, @ann_link).allowed?(:archive_link) }
    end

    assert_equal %w[deny KeyError], stamp_for(set, nil, "archive_link").to_h.values_at(:decision, :raised)
  end

  def test_a_subject_that_is_a_class_is_class_level
    set = collect_dp { DpShop::LinkPolicy.new(@ann, Shop::Link).allowed?(:create_link) }

    stamp = set.stamps.fetch(0)
    assert stamp.class_level
    assert_equal "Shop::Link", stamp.resource
    assert_nil stamp.member
  end

  # A global ability's subject is the Symbol :global, not a record.
  def test_a_global_ability_is_class_level
    set = collect_dp do
      assert DpShop::GlobalPolicy.new(@sue, :global).allowed?(:read_admin_dashboard)
      refute DpShop::GlobalPolicy.new(@ann, :global).allowed?(:read_admin_dashboard)
    end

    allow = stamp_for(set, nil, "read_admin_dashboard", decision: "allow")
    assert_equal ["DpShop::GlobalPolicy", "global", true, ["staff"]],
                 allow.to_h.values_at(:policy, :resource, :class_level, :roles)
    assert_nil allow.member
    assert stamp_for(set, nil, "read_admin_dashboard", decision: "deny", class_level: true, resource: "global")
  end
end
