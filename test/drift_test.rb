# frozen_string_literal: true

require "test_helper"
require_relative "support/fixture_solver"

# Drift: stamps the shop fixture's policy code contradicts (docs/adr/0003),
# and the facts evaluator Inference and drift share; no Java.
class DriftTest < Minitest::Test
  include Hallmark::Guard::DSL

  ROOT = File.join(HallmarkTestHelpers::FIXTURES, "apps", "shop")

  def setup
    super
    Hallmark.configuration.root = ROOT
  end

  def stamp(rule:, entry_point: "LinksController#update", decision: "allow", **facts)
    defaults = {
      policy: "LinkPolicy", resource: "Link", class_level: false, enforced: true, logged_in: true,
      in_current_tenant: true, permitted: false, roles: [], record_roles: [], current_roles: []
    }
    Hallmark::Stamp.new(**defaults, entry_point: entry_point, rule: rule, decision: decision, **facts)
  end

  def as_admin = { current_roles: ["admin"], record_roles: ["admin"] }
  def as_marketer = { current_roles: ["marketing"], record_roles: ["marketing"] }

  def analysis(stamps, &extra)
    Hallmark::Analysis.build("Shop") do
      map do
        tenant "User", membership: "TeamMembership", self: :owner, roles_in: :team_roles_for
        current_tenant :seller
        platform_role :staff
        resource "Link", tenant: :user, permits: :collaborator_for?
        grant :owner, :write, "Link"
        grant :admin, :write, "Link"
        term "user.role_owner_for?(seller)", role(:owner, tenant: :current)
        term "user.role_admin_for?(seller)", role(:admin, tenant: :current)
        term "user.role_marketing_for?(seller)", role(:marketing, tenant: :current)
        instance_eval(&extra) if extra
      end
      stamps Hallmark::StampSet.new(stamps)
    end
  end

  def drift(stamps, &) = analysis(stamps, &).inference.drift

  def link = analysis([]).mapping.fetch("Link")
  def facts(stamp) = Hallmark::StampFacts.new(analysis([]).mapping, link, stamp)

  def test_stamps_the_code_explains_are_not_drift
    assert_empty drift([stamp(rule: "update?", **as_admin), stamp(rule: "update?", decision: "deny", **as_marketer)])
  end

  # update? lets only the seller's team or a collaborator through.
  def test_an_allow_outside_the_upper_bound_is_drift
    found = drift([stamp(rule: "update?", **as_marketer)])

    assert_equal 1, found.size
    item = found.fetch(0)

    assert_equal ["LinkPolicy#update?", "Link", "allow", "app/policies/link_policy.rb:14"],
                 [item.rule, item.resource, item.decision, item.location]
    assert_equal Hallmark::Extractor.load(analysis([]).mapping).fetch("LinkPolicy", "update?").upper, item.bound
    assert_equal "logged_in & ~permitted & in_current_tenant & record_roles=[marketing] & current_roles=[marketing]",
                 item.facts
    assert_equal ["LinksController#update"], item.seen
  end

  # A rule that raised is a deny; the seller's admin is inside the lower bound.
  def test_a_deny_inside_the_lower_bound_is_drift_raises_included
    found = drift([stamp(rule: "update?", decision: "deny", raised: "ActiveRecord::RecordNotFound", **as_admin),
                   stamp(rule: "update?", decision: "deny", entry_point: nil, **as_admin)])

    assert_equal 1, found.size, "equal facts collapse into one drift"
    item = found.fetch(0)

    refute_predicate item, :allow?
    assert_equal ["LinksController#update", "outside a request"], item.seen
    assert_equal ["ActiveRecord::RecordNotFound"], item.raised
  end

  # preview? calls `user.feature_enabled?`: a deny anywhere is explained by
  # it, an allow only where the rest of the rule holds.
  def test_opaque_calls_explain_decisions_within_the_bounds
    assert_empty drift([stamp(rule: "preview?", decision: "deny", **as_admin), stamp(rule: "preview?", **as_marketer)])

    found = drift([stamp(rule: "preview?")]).map { |item| [item.rule, item.decision] }

    assert_equal [["LinkPolicy#preview?", "allow"]], found
  end

  # The stamp says nothing about explicit permission, so the upper bound is
  # unknown here, not false.
  def test_a_fact_the_stamp_lacks_is_never_drift
    assert_empty drift([stamp(rule: "update?", permitted: nil, **as_marketer)])
  end

  def test_a_hand_written_guard_replaces_the_extracted_one
    found = drift([stamp(rule: "update?", **as_marketer)]) do
      rule "LinkPolicy", :update?, guard: role(:marketing, tenant: :current)
    end

    assert_empty found
  end

  def test_drift_fails_the_report_in_its_own_section
    report = analysis([stamp(rule: "update?", **as_admin), stamp(rule: "edit?", **as_marketer)])
             .run(solver: FixtureSolver.new)

    assert_empty report.findings
    assert_predicate report, :failed?
    text = report.to_s

    assert_includes text, "Drift (stamped decisions the rule's code contradicts; the extractor or a `term` is wrong):"
    assert_includes text, "DRIFT LinkPolicy#edit? (Link) at app/policies/link_policy.rb:8: allowed, but its code " \
                          "allows only where "
    assert_includes text, "      stamped at: LinksController#update"
    assert_includes text, "1 drifting decision (stamps the rule's code contradicts)."
  end

  def test_a_deny_drift_line_names_the_lower_bound_and_the_exception
    report = analysis([stamp(rule: "update?", decision: "deny", raised: "ActiveRecord::RecordNotFound", **as_admin)])
             .run(solver: FixtureSolver.new)

    lower = Hallmark::Extractor.load(report.analysis.mapping).fetch("LinkPolicy", "update?").lower

    assert_includes report.to_s, "DRIFT LinkPolicy#update? (Link) at app/policies/link_policy.rb:14: denied " \
                                 "(raised ActiveRecord::RecordNotFound), but its code allows wherever #{lower} " \
                                 "(lower bound), true here\n"
  end

  # Every literal Inference builds from a stamp holds for that stamp.
  def test_literals_hold_for_their_stamp
    [stamp(rule: "update?", **as_admin), stamp(rule: "update?", in_current_tenant: false, **as_marketer),
     stamp(rule: "update?", permitted: true, roles: ["staff"]), stamp(rule: "update?", logged_in: false)]
      .each do |each|
      evaluated = facts(each)

      evaluated.literals.each { |literal| assert literal.evaluate(evaluated), "#{literal} on #{evaluated}" }
    end
  end

  def test_facts_follow_the_mapping_where_the_stamp_is_silent
    anonymous = facts(stamp(rule: "update?", logged_in: false, current_roles: nil, record_roles: []))

    # An anonymous visitor holds no role; Link has no owner, is never
    # public and always has a tenant.
    values = [role(:admin, tenant: :current), owner, public_record, outside_tenants].map { |leaf| anonymous[leaf] }

    assert_equal [false] * 4, values
  end

  # No current tenant was stamped, another tenant may hold the owner role,
  # and stamps do not record the catalog's Admin.
  def test_facts_a_stamp_does_not_hold_are_unknown
    elsewhere = facts(stamp(rule: "update?", in_current_tenant: false, current_roles: nil, record_roles: ["admin"]))
    leaves = [role(:admin, tenant: :current), role(:admin, tenant: :record), role(:admin, tenant: :any),
              role(:owner, tenant: :any), admin]

    values = leaves.map { |leaf| elsewhere[leaf] }

    assert_equal [nil, true, true, nil, nil], values
  end
end
