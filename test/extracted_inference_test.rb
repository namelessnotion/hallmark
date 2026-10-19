# frozen_string_literal: true

require "test_helper"
require_relative "support/fixture_solver"

# Inference and RuleCheck with guards read from the shop fixture's policy
# code beside the stamps (docs/adr/0003); no Java.
class ExtractedInferenceTest < Minitest::Test
  include Hallmark::Guard::DSL

  ROOT = File.join(HallmarkTestHelpers::FIXTURES, "apps", "shop")

  def setup
    super
    Hallmark.configuration.root = ROOT
  end

  def stamp(rule:, entry_point: "LinksController#update", decision: "allow", **facts)
    defaults = {
      policy: "LinkPolicy", resource: "Link", class_level: false, enforced: true, logged_in: true,
      in_current_tenant: true, roles: [], record_roles: [], current_roles: []
    }
    Hallmark::Stamp.new(**defaults, entry_point: entry_point, rule: rule, decision: decision, **facts)
  end

  def analysis(stamps, unchecked = [], controller: nil, routes: [])
    Hallmark::Analysis.build("Shop") do
      map do
        tenant "User", membership: "TeamMembership", self: :owner, roles_in: :team_roles_for
        current_tenant :seller, controller: controller
        platform_role :staff
        resource "Link", tenant: :user, permits: :collaborator_for?
        grant :owner, :write, "Link"
        grant :admin, :write, "Link"
        term "user.role_owner_for?(seller)", role(:owner, tenant: :current)
        term "user.role_admin_for?(seller)", role(:admin, tenant: :current)
        term "user.role_marketing_for?(seller)", role(:marketing, tenant: :current)
      end
      stamps Hallmark::StampSet.new(stamps, unchecked, routes)
    end
  end

  def route(entry_point) = Hallmark::Route.new(entry_point: entry_point, verb: "GET", path: "/")

  def team = role(:owner, tenant: :current) | role(:admin, tenant: :current)

  # The show? stamps only ever saw the seller's own product; the code allows
  # any product of any seller to a team member of the current one (M2).
  def test_an_entry_points_guard_joins_the_code_and_the_stamps
    exposure = analysis([stamp(rule: "show?", entry_point: "BundlesController#show",
                               current_roles: ["admin"], record_roles: ["admin"])]).exposures.fetch(0)

    assert_equal "BundlesController#show", exposure.action
    assert_equal logged_in & (team | role(:marketing, tenant: :current)), exposure.guard.operands[0]
    assert_equal "extracted from LinkPolicy#show? (app/policies/link_policy.rb:21); " \
                 "inferred from 1 allow-stamp of LinkPolicy#show?", exposure.basis
  end

  def test_rules_no_stamp_shows_are_units_without_entry_points
    inference = analysis([stamp(rule: "update?", current_roles: ["admin"], record_roles: ["admin"])]).inference
    keys = inference.units.map(&:key)

    assert_includes keys, "LinkPolicy#destroy?"
    assert_includes inference.coverage.code_only, "LinkPolicy#destroy?"
    refute_includes inference.coverage.code_only, "LinkPolicy#update?"
    assert_equal ["LinksController#update"], inference.exposures.map(&:action)
  end

  # Read exactly, a rule has no not-observed regions; opaque calls are listed.
  def test_coverage_lists_opaque_calls_not_stamp_gaps_for_exact_rules
    coverage = analysis([stamp(rule: "update?", current_roles: ["admin"], record_roles: ["admin"])])
               .inference.coverage

    assert_empty(coverage.gaps.select { |gap| gap.rule == "LinkPolicy#update?" })
    # preview? has an opaque call but no stamp: no empty region for it.
    assert_empty(coverage.gaps.select { |gap| gap.rule == "LinkPolicy#preview?" })
    assert_includes coverage.opaque.map(&:to_s),
                    "LinkPolicy#preview?: `user.feature_enabled?(:previews)` (app/policies/link_policy.rb:43)"
  end

  # A rule whose code allows only through unread calls has nothing certain
  # to check: it is not observed, not a pass.
  def test_rule_check_reads_code_rules_and_reports_unreadable_ones
    mapping = analysis([]).mapping
    check = Hallmark::RuleCheck.new(mapping, Hallmark::StampSet.new, extractor: Hallmark::Extractor.load(mapping))

    assert_includes check.rules("LinkPolicy"), "edit?"
    result = check.check("LinkPolicy", ["preview?"], solver: FixtureSolver.new({})).fetch(0)

    assert_equal :not_observed, result.verdict
    assert_match(/calls Hallmark could not read/, result.reason)
  end

  # Step 3: a record the controller loads through the current seller is in
  # the current tenant, whatever the rule allows; one loaded by id alone is
  # not.
  def test_a_scoped_load_puts_the_record_in_the_current_tenant
    allow = { current_roles: ["admin"], record_roles: ["admin"] }
    stamps = [stamp(rule: "show?", entry_point: "LinksController#destroy", **allow),
              stamp(rule: "show?", entry_point: "LinksController#edit", **allow)]
    exposures = analysis(stamps, controller: :current_seller).exposures.to_h { |exposure| [exposure.action, exposure] }
    scoped = exposures.fetch("LinksController#destroy")

    assert_equal in_current_tenant, scoped.guard.operands[0]
    assert_match(%r{record loaded through current_seller \(app/controllers/links_controller.rb:26\)\z}, scoped.basis)
    refute_equal in_current_tenant, exposures.fetch("LinksController#edit").guard.operands[0]
  end

  # Unchecked requests to actions the controller exempts from
  # verify_authorized are intended; where it declares nothing, they fail.
  def test_verify_authorized_exemptions_excuse_unchecked_requests
    unchecked = %w[LinksController#show Admin::ReportsController#index].map do |entry_point|
      Hallmark::Unchecked.new(entry_point: entry_point, status: 200, verb: "GET")
    end
    inference = analysis([], unchecked).inference

    assert_equal ["Admin::ReportsController#index"], inference.unchecked
    assert_equal ["LinksController#show"], inference.coverage.exempt
  end

  # Routes no test reached become exposures from the rules their code
  # authorizes; what cannot be read is listed, never failed.
  def test_routes_no_test_reached
    names = %w[LinksController#edit LinksController#destroy LinksController#show Admin::ReportsController#index
               LinksController#preview Devise::SessionsController#new LinksController#update]
    stamps = [stamp(rule: "update?", entry_point: "LinksController#update", current_roles: ["admin"],
                    record_roles: ["admin"])]
    inference = analysis(stamps, controller: :current_seller, routes: names.map { |name| route(name) }).inference
    exposures = inference.exposures.to_h { |exposure| [exposure.action, exposure] }

    assert_equal %w[LinksController#destroy LinksController#edit LinksController#update], exposures.keys.sort
    assert_match(/\Ano test reached this route, read from code: extracted from LinkPolicy#edit\?/,
                 exposures.fetch("LinksController#edit").basis)
    assert_equal in_current_tenant, exposures.fetch("LinksController#destroy").guard.operands[0]
    assert_equal ["Admin::ReportsController#index"], inference.coverage.routes_unchecked
    assert_equal ["LinksController#preview"], inference.coverage.routes_unresolved
    assert_equal ["Devise::SessionsController#new"], inference.coverage.routes_unread
  end

  # A check the controller makes in its own code joins the exposure's
  # guard by its lower bound: show? asks only for a role in the current
  # seller (M2), but the shared filter also requires the seller's own link
  # or a collaborator. A check Hallmark cannot read leaves nothing certain:
  # the entry point is listed, not checked, and so is the call.
  def test_controller_checks_join_the_exposure
    names = %w[ProductsController#publish ProductsController#preview ProductsController#stats]
    inference = analysis([], controller: :current_seller, routes: names.map { |name| route(name) }).inference
    exposures = inference.exposures.to_h { |exposure| [exposure.action, exposure] }
    rule = exposures.fetch("ProductsController#stats").guard

    assert_equal rule & (in_current_tenant | permitted), exposures.fetch("ProductsController#publish").guard
    assert_match(%r{; checked in the controller \(app/controllers/application_controller.rb:21\)\z},
                 exposures.fetch("ProductsController#publish").basis)
    refute exposures.key?("ProductsController#preview")
    assert_equal ["ProductsController#preview"], inference.coverage.checks_unread
    assert_includes inference.coverage.opaque.map(&:to_s),
                    "ProductsController#preview: `record.previewable?` (app/controllers/products_controller.rb:39)"
  end

  def test_extraction_can_be_turned_off
    Hallmark.configuration.extract = false
    inference = analysis([stamp(rule: "update?", current_roles: ["admin"], record_roles: ["admin"])]).inference

    assert_equal ["LinkPolicy#update?"], inference.units.map(&:key)
  end
end
