# frozen_string_literal: true

require "test_helper"

# How a finding words its witness: the intended pattern follows the way the
# witness got in, and a current tenant the app never declared stays out of
# the message. Both seen on the Forem run (organizations as tenants, no
# current tenant), with witnesses written by hand so no solver is needed.
class FindingTest < Minitest::Test
  include Hallmark::Guard::DSL

  def articles(guard, current: nil)
    Hallmark::Analysis.build("Articles") do
      map do
        tenant "Organization", membership: "OrganizationMembership"
        current_tenant current if current
        resource "Article", owner: :user, tenant: :organization, tenant_optional: true
      end
      writes "ArticlesController#update", "Article", guard: guard
    end
  end

  # User$1 owns Article$0 in Organization$0, where they hold no role, and is
  # an org_admin of Organization$1, the witness's current tenant.
  def owner_witness(exposure)
    check = exposure.check_name
    Hallmark::Receipt::Instance.new(
      {
        "owner" => [["Article$0", "catalog/User$1"]],
        "tenant" => [["Article$0", "catalog/Tenant$0"]],
        "member" => [["catalog/Membership$0", "catalog/User$1"]],
        "within" => [["catalog/Membership$0", "catalog/Tenant$1"]],
        "roles" => [["catalog/Membership$0", "Role_org_admin$0"]]
      },
      {
        "$#{check}_p" => [["catalog/User$1"]],
        "$#{check}_r" => [["Article$0"]],
        "$#{check}_cur" => [["catalog/Tenant$1"]]
      }
    )
  end

  def finding(analysis)
    exposure = analysis.exposures.fetch(0)
    Hallmark::Finding.from(exposure, owner_witness(exposure), analysis.mapping)
  end

  def owner_or_org_admin = logged_in & (owner | role(:org_admin, tenant: :record))

  def test_an_undeclared_current_tenant_stays_out_of_the_message
    finding = finding(articles(owner_or_org_admin))

    assert_nil finding.current_tenant
    refute_predicate finding, :cross_tenant?
    assert_equal "a signed-in User (User$1) holding no roles can update an Article they own " \
                 "in tenant Organization$0, where they hold no roles", finding.message
    assert_equal "if its owner may update it without being a member of its tenant, declare it in the map block: " \
                 "resource \"Article\", ..., owner_outside_tenant: :write", finding.hint
  end

  def test_a_declared_current_tenant_is_named
    finding = finding(articles(owner_or_org_admin, current: :current_organization))

    refute_nil finding.current_tenant
    assert_predicate finding, :cross_tenant?
    assert_includes finding.message, "holding roles org_admin in the current tenant Organization$1"
  end

  # A guard that reads the current tenant needs it, declared or not.
  def test_a_guard_reading_the_current_tenant_keeps_it
    finding = finding(articles(logged_in & (owner | role(:org_admin, tenant: :current))))

    refute_nil finding.current_tenant
    assert_includes finding.message, "in the current tenant Organization$1"
  end

  # The guard names a role, but the witness got in as the owner.
  def test_the_pattern_follows_the_way_the_witness_got_in
    assert_equal "Ownership", finding(articles(owner_or_org_admin)).pattern
  end

  def build(guard, roles: [], rules: nil, permits: nil)
    analysis = Hallmark::Analysis.build("Organizations") do
      map { resource "Organization", permits: permits }
    end
    analysis.add_exposure(action: "Api::OrganizationsController#create", op: :write, resource: "Organization",
                          guard: guard, rules: rules)
    analysis.validate!
    Hallmark::Finding.new(exposure: analysis.exposures.fetch(0), mapping: analysis.mapping,
                          principal: "catalog/User$0", record: "Organization$0", owner: nil, roles: roles)
  end

  def test_patterns_name_what_the_mapping_declares
    assert_equal "Public actions", build(logged_in, rules: ["OrganizationPolicy#create?"]).pattern
    assert_equal "Explicit permission (a grant to a role)", build(role(:moderator), roles: ["moderator"]).pattern
    assert_equal "Explicit permission (a grant to a role)", build(logged_in & role(:moderator)).pattern

    assert_equal "Explicit permission on a record", build(permitted, permits: :collaborator_for?).pattern
  end
end
