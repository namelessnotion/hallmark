# frozen_string_literal: true

require "test_helper"
require_relative "collectors/shop_people"
require_relative "support/fixture_solver"

# Rules checked one at a time, the unit behind the RSpec matchers. Guards
# come from stamps the Action Policy shop records, or from the mapping; the
# solver is FixtureSolver, so no Java is needed.
class RuleCheckTest < Minitest::Test
  include ShopPeople

  POLICY = "ApShop::LinkPolicy"
  UPDATE = "safe_ApShop_LinkPolicy_update_write_Shop_Link"

  def mapping(&block)
    mapping = Shop.map(Hallmark::Mapping.new)
    mapping.instance_eval(&block) if block
    mapping
  end

  # edit? allowed in the seller's own shop; update? allowed across sellers
  # (M2); destroy? only ever raises, so it never allowed.
  def stamps
    collect do
      Shop.request(ApShop::LinksController, :edit, user: @ann, seller: @ann, link: @ann_link)
      Shop.request(ApShop::LinksController, :update, user: @ada, seller: @ann, link: @bob_link)
      assert_raises(KeyError) do
        Shop.request(ApShop::LinksController, :destroy, user: @ada, seller: @ann, link: @ann_link)
      end
    end
  end

  def stamp(rule, resource, **facts)
    Hallmark::Stamp.new(policy: POLICY, rule: rule, resource: resource, decision: "allow", enforced: true,
                        logged_in: true, **facts)
  end

  def test_lists_stamped_and_hand_written_rules
    check = Hallmark::RuleCheck.new(mapping do
      rule POLICY, :publish?, guard: role(:owner, tenant: :current) & in_current_tenant, resource: "Shop::Link"
      rule POLICY, :archive?, op: :write
    end, stamps)

    assert_equal %w[destroy? edit? publish? update?], check.rules(POLICY)
    assert_empty check.rules("PunditShop::LinkPolicy")
  end

  def test_checks_each_rule_on_its_own_in_one_run
    solver = FixtureSolver.new
    results = Hallmark::RuleCheck.new(mapping, stamps).check(POLICY, solver: solver)

    assert_equal([%w[destroy? not_observed], %w[edit? none], %w[update? none]],
                 results.map { |result| [result.rule, result.verdict.to_s] })
    assert_equal ["safe_ApShop_LinkPolicy_edit_read_Shop_Link", UPDATE], solver.checks
    assert_equal "inferred from 1 allow-stamp of ApShop::LinkPolicy#update?", results.last.exposure.basis
  end

  def test_explains_a_counterexample_as_hallmark_check_prints_it
    result = Hallmark::RuleCheck.new(mapping, stamps)
                                .check(POLICY, ["update?"], solver: FixtureSolver.new(UPDATE => :counterexample)).first

    assert_predicate result, :counterexample?
    assert_equal Hallmark::Report.finding_lines(result.finding), result.lines
    assert_equal "FAIL  ApShop::LinkPolicy#update? (write Shop::Link)", result.lines.first
    assert_match(/can update a Shop::Link .* in tenant Shop::User\$\d, where they hold no roles/, result.lines.join)
  end

  def test_an_unknown_keeps_its_reason
    result = Hallmark::RuleCheck.new(mapping, stamps)
                                .check(POLICY, ["update?"], solver: FixtureSolver.new(UPDATE => "timed out after 9 s"))
                                .first

    assert_equal :unknown, result.verdict
    assert_equal ["??    ApShop::LinkPolicy#update? (write Shop::Link): unknown, timed out after 9 s"], result.lines
  end

  def test_a_rule_that_never_allowed_is_not_observed
    solver = FixtureSolver.new
    result = Hallmark::RuleCheck.new(mapping, stamps).check(POLICY, ["destroy?"], solver: solver).first

    assert_equal :not_observed, result.verdict
    assert_equal ["--    ApShop::LinkPolicy#destroy?: not observed, no allow-stamp was recorded (1 deny-stamp) " \
                  "and the mapping declares no guard for it"], result.lines
    assert_empty solver.models
  end

  def test_says_why_a_rule_without_a_unit_was_not_observed
    set = Hallmark::StampSet.new([stamp("create?", "Shop::Link", class_level: true),
                                  stamp("show?", "Shop::Coupon")])
    results = Hallmark::RuleCheck.new(mapping, set).check(POLICY, %w[create? show? index?], solver: FixtureSolver.new)

    assert_equal ["checked only against a class or a name, not a record (not modeled)",
                  "stamped on unmapped resources (Shop::Coupon); map them with `resource`",
                  "no stamp of it was recorded and the mapping declares no guard for it"], results.map(&:reason)
  end

  def test_a_hand_written_guard_needs_no_stamps
    check = Hallmark::RuleCheck.new(mapping do
      rule "Shop::LinkPolicy", :update?, guard: role(:admin, tenant: :current) & in_current_tenant
    end)
    result = check.check("Shop::LinkPolicy", solver: FixtureSolver.new).first

    assert_equal :none, result.verdict
    assert_equal "Shop::Link", result.exposure.resource
    assert_equal "hand-written for Shop::LinkPolicy#update?", result.exposure.basis
  end

  def test_a_hand_written_guard_names_its_resource_when_the_policy_name_does_not
    check = Hallmark::RuleCheck.new(mapping { rule "Admin::LinkPolicy", :update?, guard: role(:staff) })
    error = assert_raises(Hallmark::ConfigurationError) { check.check("Admin::LinkPolicy", solver: FixtureSolver.new) }

    assert_match(/add `resource:`/, error.message)
  end

  def test_a_declared_rule_resource_must_be_mapped
    error = assert_raises(Hallmark::ConfigurationError) do
      Hallmark::RuleCheck.new(mapping { rule POLICY, :update?, guard: role(:staff), resource: "Shop::Coupon" })
    end

    assert_match(/Shop::Coupon is not mapped/, error.message)
  end

  def test_a_rule_on_two_resources_gets_a_check_for_each
    set = Hallmark::StampSet.new([stamp("show?", "Shop::Link"), stamp("show?", "Shop::Note")])
    results = Hallmark::RuleCheck.new(mapping { resource "Shop::Note" }, set).check(POLICY, solver: FixtureSolver.new)

    assert_equal(%w[safe_ApShop_LinkPolicy_show_read_Shop_Link safe_ApShop_LinkPolicy_show_read_Shop_Note],
                 results.map { |result| result.exposure.check_name })
    assert_equal(["ApShop::LinkPolicy#show?"], results.map { |result| result.exposure.action }.uniq)
  end
end
