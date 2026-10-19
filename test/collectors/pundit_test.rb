# frozen_string_literal: true

require "test_helper"
require_relative "shop_people"

class PunditCollectorTest < Minitest::Test
  include ShopPeople

  UPDATE = "PunditShop::LinksController#update"

  def test_stamps_allows_and_denies_with_the_entry_point
    set = collect do
      assert_equal 200, Shop.request(PunditShop::LinksController, :update, user: @ada, seller: @ann, link: @bob_link)
      assert_equal 403, Shop.request(PunditShop::LinksController, :update, user: @mia, seller: @ann, link: @ann_link)
    end

    allow = stamp_for(set, UPDATE, "update?", decision: "allow")
    assert_equal "PunditShop::LinkPolicy", allow.policy
    assert allow.enforced
    assert_equal [false, ["admin"]], allow.to_h.values_at(:in_current_tenant, :current_roles)
    deny = stamp_for(set, UPDATE, "update?", decision: "deny")
    assert_equal [true, ["marketing"]], deny.to_h.values_at(:in_current_tenant, :record_roles)
  end

  # The policy reads the user off Gumroad's context; the mapping's default
  # reader (`policy.user`) finds it.
  def test_reads_the_user_through_a_context_object
    set = collect { Shop.request(PunditShop::LinksController, :edit, user: @sue, seller: @bob, link: @bob_link) }

    stamp = stamp_for(set, "PunditShop::LinksController#edit", "edit?")
    assert_equal ["deny", ["staff"]], stamp.to_h.values_at(:decision, :roles)
  end

  # Gumroad's error handler compares `error.query` with a String; the hook
  # must not turn the caller's Symbol into one.
  def test_passes_the_query_to_pundit_unchanged
    set = collect do
      assert_equal 403, Shop.request(PunditShop::LinksController, :publish, user: @mia, seller: @ann, link: @ann_link)
    end

    assert_equal :update?, Shop.denied_query
    assert stamp_for(set, "PunditShop::LinksController#publish", "update?", decision: "deny")
  end

  # A collaborator on another seller's link, acting for their own account.
  def test_stamps_explicit_permissions_for_the_rules_op
    Shop.collaborations.replace([[@sam, @bob_link]])
    set = collect do
      Shop.request(PunditShop::LinksController, :update, user: @sam, seller: @sam, link: @bob_link)
      Shop.request(PunditShop::LinksController, :edit, user: @sam, seller: @sam, link: @bob_link)
      Shop.request(PunditShop::LinksController, :update, user: @ada, seller: @ann, link: @ann_link)
    end

    assert stamp_for(set, UPDATE, "update?", decision: "allow", permitted: true, in_current_tenant: false)
    assert stamp_for(set, "PunditShop::LinksController#edit", "edit?", permitted: false)
    assert stamp_for(set, UPDATE, "update?", decision: "allow", permitted: false)
  ensure
    Shop.collaborations.clear
  end

  # A service object authorizing outside a request: the app sees exactly what
  # Pundit gives it, and the stamps have no entry point but stay enforced, as
  # Action Policy's and DeclarativePolicy's do.
  def test_authorize_outside_a_request_gets_no_entry_point
    set = nil
    assert_output(nil, "") do
      set = collect do
        assert_same @ann_link, PunditShop::ProductPublisher.new(@ada, @ann).publish(@ann_link)
        error = assert_raises(Pundit::NotAuthorizedError) do
          PunditShop::ProductPublisher.new(@mia, @ann).publish(@ann_link)
        end
        assert_equal :update?, error.query
      end
    end

    assert stamp_for(set, nil, "update?", decision: "allow", enforced: true)
    assert stamp_for(set, nil, "update?", decision: "deny", enforced: true)
  end

  # With no query and no `action_name`, Pundit fails on its own; the hook
  # adds nothing and stamps nothing.
  def test_a_missing_query_outside_a_request_fails_as_pundit_does
    set = nil
    assert_output(nil, "") do
      set = collect do
        publisher = PunditShop::ProductPublisher.new(@ada, @ann)
        error = assert_raises(NameError) { publisher.publish(@ann_link, nil) }
        assert_equal :action_name, error.name
        assert_match(%r{/pundit/}, error.backtrace&.first.to_s)
        publisher.publish(@ann_link) # one stamped call, since an empty run has no stamp file
      end
    end

    assert_equal([[nil, "update?", "allow"]],
                 set.stamps.map { |stamp| [stamp.entry_point, stamp.rule, stamp.decision] })
  end

  # A headless policy checks a Symbol, alone or last in a namespaced array.
  def test_a_headless_policy_is_class_level
    set = collect do
      assert_equal :dashboard, PunditShop::DashboardReport.new(@sue, nil).build
      assert_equal :dashboard, PunditShop::DashboardReport.new(@sue, nil).build(%i[admin dashboard])
      assert_raises(Pundit::NotAuthorizedError) { PunditShop::DashboardReport.new(@ann, @ann).build }
    end

    assert_equal([["allow", "dashboard", true], ["deny", "dashboard", true]],
                 set.stamps.map { |stamp| stamp.to_h.values_at(:decision, :resource, :class_level) }.sort)
    assert_equal ["PunditShop::DashboardPolicy", true], stamp_for(set, nil, "show?").to_h.values_at(:policy, :enforced)
  end

  def test_anonymous_requests_are_stamped
    set = collect { Shop.request(PunditShop::LinksController, :update, link: @ann_link) }

    stamp = stamp_for(set, UPDATE, "update?")
    assert_equal ["deny", false], stamp.to_h.values_at(:decision, :logged_in)
  end

  # Forem's policy specs, and pundit-matchers' `permit_actions`, build the
  # policy and call the rule themselves: a query, with no entry point.
  def test_stamps_rules_called_directly_on_a_policy
    set = collect do
      policy = PunditShop::LinkPolicy.new(PunditShop::Context.new(@ada, @ann), @bob_link)
      assert_predicate policy, :update?
      refute_predicate policy, :edit?
    end

    allow = stamp_for(set, nil, "update?", decision: "allow")
    assert_equal ["PunditShop::LinkPolicy", false, false], allow.to_h.values_at(:policy, :enforced, :in_current_tenant)
    assert stamp_for(set, nil, "edit?", decision: "deny", enforced: false)
  end

  # Pundit's `authorize` calls the rule on the policy; that call is the
  # enforced stamp alone.
  def test_authorize_stamps_its_rule_once
    set = collect { Shop.request(PunditShop::LinksController, :update, user: @ada, seller: @ann, link: @bob_link) }

    assert_equal([[UPDATE, "update?", true]],
                 set.stamps.map { |stamp| [stamp.entry_point, stamp.rule, stamp.enforced] })
  end

  def test_a_policy_loaded_later_gets_its_calls_through_untouched
    set = collect_late_policy do |policy|
      transfer = PunditShop::LatePolicy::Transfer
      given = policy.transfer?(:bob, { a: 1 }, notify: true) { :called }
      assert_equal transfer.new(:bob, { a: 1 }, true, :called), given
      assert_equal transfer.new(:bob, nil, false, nil), policy.transfer?(:bob)
      error = assert_raises(KeyError) { policy.archive? }
      assert_equal "no membership", error.message
    end

    assert_equal([["PunditShop::LatePolicy", "archive?", "deny", "KeyError"],
                  ["PunditShop::LatePolicy", "transfer?", "allow", nil]],
                 set.stamps.map { |stamp| stamp.to_h.values_at(:policy, :rule, :decision, :raised) }.uniq.sort)
  end

  # `destroy?` calls `update?`, which calls the `update?` it overrides: one
  # stamp, for the rule the caller called.
  def test_rules_called_from_a_rule_are_not_stamped_again
    set = collect_late_policy { |policy| assert_same true, policy.destroy? }

    assert_equal([["destroy?", "allow"]], set.stamps.map { |stamp| [stamp.rule, stamp.decision] })
  end

  # Only Pundit policies get wrappers: not Action Policy's or
  # DeclarativePolicy's, which their own hooks observe, nor Rails' `*Policy`
  # classes, which Pundit could not build.
  def test_wraps_only_pundit_policies
    collect { PunditShop::LinkPolicy.new(PunditShop::Context.new(@ada, @ann), @ann_link).update? }

    refute_same PunditShop::LinkPolicy, PunditShop::LinkPolicy.ancestors.first
    [ApShop::LinkPolicy, DpShop::LinkPolicy, ActionDispatch::ContentSecurityPolicy].each do |klass|
      assert_same klass, klass.ancestors.first
    end
  end

  private

  # Loads PunditShop::LatePolicy once the collectors are on, and yields one
  # built for the vendor's staff acting for ann.
  def collect_late_policy
    collect do
      load File.expand_path("../support/late_pundit_policy.rb", __dir__)
      yield PunditShop::LatePolicy.new(PunditShop::Context.new(@sue, @ann), @ann_link)
    end
  ensure
    PunditShop.send(:remove_const, :LatePolicy) if PunditShop.const_defined?(:LatePolicy, false)
  end
end
