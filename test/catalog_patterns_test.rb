# frozen_string_literal: true

require "test_helper"
require_relative "support/fixture_solver"

# The two patterns the phase 2 gate found missing (HCB): ownership without
# membership (`resource ..., owner_outside_tenant:`) and public actions
# (`public_action`).
class CatalogPatternsTest < Minitest::Test
  include Hallmark::Guard::DSL

  # HCB-shaped: card grants live in an organization and are owned by the
  # person they were given to, who may be outside its team.
  def grants(guard, op: :read, outside: nil)
    Hallmark::Analysis.build("Grants") do
      map do
        tenant "Organization", membership: "OrganizerPosition"
        resource "CardGrant", owner: :user, tenant: :organization, owner_outside_tenant: outside
        grant :reader, :read, "CardGrant"
      end
      if op == :read
        reads("CardGrantsController#show", "CardGrant", guard: guard)
      else
        writes("CardGrantsController#cancel", "CardGrant", guard: guard)
      end
    end
  end

  def test_owner_outside_tenant_validates
    mapping = Hallmark::Mapping.new
    mapping.resource "A", owner: :user, tenant: :organization, owner_outside_tenant: true
    mapping.resource "B", owner: :user, tenant: :organization, owner_outside_tenant: :read

    assert_equal %i[read write], mapping.fetch("A").owner_outside_ops
    assert_equal %i[read], mapping.fetch("B").owner_outside_ops
    assert_raises(Hallmark::ConfigurationError) { mapping.resource "C", tenant: :organization, owner_outside_tenant: true }
    assert_raises(Hallmark::ConfigurationError) { mapping.resource "D", owner: :user, owner_outside_tenant: true }
    assert_raises(Hallmark::ConfigurationError) do
      mapping.resource "E", owner: :user, tenant: :organization, owner_outside_tenant: :delete
    end
  end

  def test_the_model_pins_down_who_needs_membership
    with = Hallmark::ModelBuilder.new(grants(owner, outside: :read)).source
    without = Hallmark::ModelBuilder.new(grants(owner)).source

    assert_includes with, "fact CardGrant_owner_outside_tenant { all r: CardGrant | r.ownerOutside = Read }"
    assert_includes without, "fact owners_need_membership { no ownerOutside }"
  end

  def test_an_owner_outside_the_tenant_is_a_finding_until_mapped
    solver = require_solver!
    finding = grants(logged_in & owner).run(solver: solver).findings.fetch(0)

    assert_empty finding.record_tenant.roles
    assert_predicate finding, :own_record?
    assert_predicate grants(logged_in & owner, outside: true).run(solver: solver), :clean?
  end

  # `:read` covers reading only.
  def test_owner_outside_tenant_covers_the_ops_it_names
    solver = require_solver!

    assert_predicate grants(owner, outside: :read).run(solver: solver), :clean?
    refute_predicate grants(owner, op: :write, outside: :read).run(solver: solver), :clean?
  end

  # Also when the request acts for another tenant: the owner is the likelier
  # intent than the tenant check.
  def test_the_owner_hint_names_the_declaration
    analysis = grants(owner)
    hints = [tenant_roles(0), tenant_roles(1)].map do |current|
      Hallmark::Finding.new(exposure: analysis.exposures.fetch(0), mapping: analysis.mapping,
                            principal: "catalog/User$0", record: "CardGrant$0", owner: "catalog/User$0", roles: [],
                            current_tenant: current, record_tenant: tenant_roles(0)).hint
    end

    assert_equal ["if its owner may read it without being a member of its tenant, declare it in the map block: " \
                  "resource \"CardGrant\", ..., owner_outside_tenant: :read"] * 2, hints
  end

  def tenant_roles(atom) = Hallmark::Finding::TenantRoles.new(tenant: "catalog/Tenant$#{atom}", user: nil, roles: [])

  # A donation page: rule checks of DonationPolicy, as `hallmark rules` makes them.
  def donations(guard, rule: "DonationPolicy#make_donation?", &declare)
    analysis = Hallmark::Analysis.build("Donations") do
      map do
        resource "Donation", flags: %i[donations_enabled]
        instance_eval(&declare) if declare
      end
    end
    analysis.add_exposure(action: rule, op: :write, resource: "Donation", guard: guard, rules: [rule])
    analysis.validate!
  end

  def test_public_action_validates
    mapping = Hallmark::Mapping.new
    actions = mapping.public_action "DonationPolicy", :start_donation?, :make_donation?

    assert_equal %w[DonationPolicy#start_donation? DonationPolicy#make_donation?], actions.map(&:key)
    assert_raises(Hallmark::ConfigurationError) { mapping.public_action "DonationPolicy", :make_donation? }
    assert_raises(Hallmark::ConfigurationError) { mapping.public_action "EventPolicy", :index?, audience: :staff }
    assert_raises(Hallmark::ConfigurationError) { mapping.public_action "EventPolicy" }
    assert_raises(Hallmark::ConfigurationError) { mapping.public_action "EventPolicy", :x?, when: logged_in }
  end

  # An entry point gets the pattern only when every rule it enforces has
  # it: the narrowest audience and both conditions.
  def test_an_entry_point_combines_its_rules_public_actions
    mapping = Hallmark::Mapping.new
    mapping.public_action "P", :a?
    mapping.public_action "P", :b?, audience: :signed_in, when: flag(:open)

    combined = mapping.public_action_for(%w[P#a? P#b?])

    assert_equal :signed_in, combined.audience
    assert_equal "flag(:open)", combined.condition.to_s
    assert_nil mapping.public_action_for(%w[P#a? P#c?])
    assert_nil mapping.public_action_for([])
  end

  def test_the_model_opens_a_public_action_to_its_audience
    source = Hallmark::ModelBuilder.new(donations(none) do
      public_action "DonationPolicy", :make_donation?, audience: :signed_in, when: flag(:donations_enabled)
    end).source

    assert_includes source, "-- public action for signed-in users where flag(:donations_enabled)"
    assert_includes source, "implies (allowed[p, Write, r] or " \
                            "(publicAction[p, User] and r in RecordFlags.flag_donations_enabled))"
  end

  def test_a_public_action_passes_for_its_audience
    solver = require_solver!
    refute_predicate donations(none).run(solver: solver), :clean?
    assert_predicate donations(none) { public_action "DonationPolicy", :make_donation? }.run(solver: solver), :clean?
  end

  # For signed-in users only, an anonymous visitor is still a finding;
  # with `when:`, so is a record the condition leaves out.
  def test_a_public_action_limits_its_audience_and_records
    solver = require_solver!
    signed_in = donations(none) { public_action "DonationPolicy", :make_donation?, audience: :signed_in }
    flagged = proc { public_action "DonationPolicy", :make_donation?, when: flag(:donations_enabled) }

    assert_predicate signed_in.run(solver: solver).findings.fetch(0), :anonymous?
    assert_predicate donations(logged_in) { public_action "DonationPolicy", :make_donation?, audience: :signed_in }
      .run(solver: solver), :clean?
    refute_predicate donations(none, &flagged).run(solver: solver), :clean?
    assert_predicate donations(flag(:donations_enabled), &flagged).run(solver: solver), :clean?
  end

  def public_hint(guard, principal)
    analysis = donations(guard)
    Hallmark::Finding.new(exposure: analysis.exposures.fetch(0), mapping: analysis.mapping, principal: principal,
                          record: "Donation$0", owner: nil, roles: []).hint
  end

  # For signed-in users only when the guard checks sign-in.
  def test_the_public_hint_names_the_rules
    everyone = "if this is meant for everyone, declare it in the map block: " \
               "public_action \"DonationPolicy\", :make_donation?"

    assert_equal everyone, public_hint(none, "catalog/Anonymous$0")
    assert_equal everyone, public_hint(none, "catalog/User$0")
    assert_equal "if this is meant for every signed-in user, declare it in the map block: " \
                 "public_action \"DonationPolicy\", :make_donation?, audience: :signed_in",
                 public_hint(logged_in, "catalog/User$0")
    assert_nil public_hint(owner | logged_in, "catalog/User$0")
  end

  # `hallmark rules` checks each rule with the rule on its exposure, so a
  # public action reaches the model.
  def test_rule_checks_carry_their_rule
    mapping = Hallmark::Mapping.new
    mapping.resource "Event"
    mapping.public_action "EventPolicy", :ledger?
    root = File.join(HallmarkTestHelpers::FIXTURES, "apps", "board")
    check = Hallmark::RuleCheck.new(mapping, extractor: Hallmark::Extractor.new(mapping, root))
    solver = FixtureSolver.new
    result = check.check("EventPolicy", ["ledger?"], solver: solver).fetch(0)

    assert_equal ["EventPolicy#ledger?"], result.exposure.rules
    assert_includes solver.models.fetch(0).source, "publicAction[p, Principal]"
  end
end
