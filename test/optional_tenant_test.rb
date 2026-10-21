# frozen_string_literal: true

require "test_helper"

# Records whose tenant is optional (`tenant_optional:`): an article posted
# under an organization or under its author alone. An owner's allow on a
# personal article must not stand for articles in an organization.
class OptionalTenantTest < Minitest::Test
  include Hallmark::Guard::DSL

  def articles(guard)
    Hallmark::Analysis.build("Articles") do
      map do
        tenant "Organization", membership: "OrganizationMembership"
        resource "Article", owner: :user, tenant: :organization, tenant_optional: true
      end
      writes "ArticlesController#update", "Article", guard: guard
    end
  end

  # Without `outside_tenants`, an owner who left the organization keeps
  # editing its articles.
  def test_owner_alone_reaches_articles_in_an_organization
    solver = require_solver!
    report = articles(logged_in & owner).run(solver: solver)

    finding = report.findings.fetch(0)
    refute_nil finding.record_tenant
    assert_empty finding.record_tenant.roles
  end

  def test_owner_outside_tenants_or_member_of_the_records_tenant_has_no_counterexample
    solver = require_solver!
    report = articles(logged_in & owner & (outside_tenants | role(:admin, tenant: :record))).run(solver: solver)

    assert_predicate report, :clean?
  end

  def test_findings_on_records_outside_tenants_say_so
    analysis = articles(logged_in)
    finding = Hallmark::Finding.new(exposure: analysis.exposures.fetch(0), mapping: analysis.mapping,
                                    principal: "catalog/User$0", record: "Article$0", owner: "catalog/User$1",
                                    roles: [])

    assert_equal "a signed-in User (User$0) holding no roles can update an Article owned by User$1 outside any tenant",
                 finding.message
  end
end
