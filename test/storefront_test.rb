# frozen_string_literal: true

require "test_helper"

# Tenant-aware checks on a Gumroad-shaped store, using the real Alloy jar:
# current-tenant confusion (M2 in docs/PLAN.md) and its fix, plus the other
# membership flaws the shipped catalog can express.
class StorefrontTest < Minitest::Test
  def test_reproduces_current_tenant_confusion
    solver = require_solver!
    report = load_example("storefront/hallmark.rb").run(solver: solver)

    assert_equal(%w[LinksController#update LinksController#edit Admin::LinksController#show LinksController#index],
                 report.findings.map { |finding| finding.exposure.action })
    assert_equal ["LinksController#edit", "Admin::LinksController#update"], report.verified.map(&:action)

    finding = report.findings.fetch(0)
    refute_predicate finding, :anonymous?
    assert_predicate finding, :cross_tenant?
    assert_empty finding.record_tenant.roles
  end

  def test_fixed_version_has_no_counterexamples
    solver = require_solver!
    report = load_example("storefront/hallmark_fixed.rb").run(solver: solver)

    assert_predicate report, :clean?
    assert_equal 6, report.verified.size
    refute_includes report.to_s, "Fields with no field policy"
  end

  # The edit page shows revenue to marketing, which the field policy does
  # not allow; the staff page shows buyers' emails, which a restriction
  # forbids even though the catalog lets staff read any product.
  def test_field_policy_and_restriction_findings
    solver = require_solver!
    report = load_example("storefront/hallmark.rb").run(solver: solver)
    findings = report.findings.to_h { |finding| [finding.exposure.target, finding] }

    revenue = findings.fetch("Link.revenue")
    assert_predicate revenue, :field_policy_broken?
    assert_nil revenue.restriction
    assert_includes revenue.current_tenant.roles, "marketing"
    buyers = findings.fetch("Link.buyer_emails")
    assert_equal "staff never see buyers", buyers.restriction&.name
    assert_includes buyers.roles, "staff"
  end

  # The dashboard's list spans every seller the user works for, and Link
  # is mapped `lists: :current_tenant` (M5).
  def test_a_list_spanning_tenants
    solver = require_solver!
    report = load_example("storefront/hallmark.rb").run(solver: solver)
    finding = report.findings.find { |found| found.exposure.list? }

    assert_equal "list_LinksController_index_Link", finding.exposure.check_name
    assert_predicate finding, :list_across_tenants?
    refute_empty finding.record_tenant.roles
    assert_match(/lists a Link \(Link\$\d\) of another User \(User\$\d\), where they hold roles .+, while acting for/,
                 finding.message)
  end

  # Scope 2 still finds M2: the builder raises Principal to 3 so that two
  # tenants, each a User, fit beside Anonymous.
  def test_current_tenant_confusion_shows_at_the_minimum_scope
    solver = require_solver!
    Hallmark.configure { |config| config.scope = 2 }
    report = load_example("storefront/hallmark.rb").run(solver: solver)

    assert_predicate report.findings.fetch(0), :cross_tenant?
  end

  def organizations(&)
    Hallmark::Analysis.build("Organizations") do
      map do
        tenant "Organization", membership: "Membership", member: :user, roles: :role
        resource "Project", tenant: :organization, owner: :creator
        grant :admin, :write, "Project"
      end
      instance_eval(&)
    end
  end

  # The same flaw where tenants are organizations, not users
  def test_current_tenant_confusion_with_organizations
    solver = require_solver!
    report = organizations do
      writes "ProjectsController#update", "Project", guard: role(:admin, tenant: :current)
      writes "ProjectsController#destroy", "Project", guard: role(:admin, tenant: :current) & in_current_tenant
    end.run(solver: solver)

    assert_equal ["ProjectsController#destroy"], report.verified.map(&:action)
    finding = report.findings.fetch(0)
    assert_predicate finding, :cross_tenant?
    assert_match(/in the current tenant Organization\$\d .* in tenant Organization\$\d, where they hold/,
                 finding.message)
  end

  # M1: an admin role held anywhere, and M3: ownership after leaving the tenant
  def test_unscoped_roles_and_ownership_outliving_membership
    solver = require_solver!
    report = organizations do
      writes "ProjectsController#archive", "Project", guard: role(:admin, tenant: :any)
      writes "ProjectsController#rename", "Project", guard: logged_in & owner
      writes "ProjectsController#move", "Project", guard: role(:admin, tenant: :record)
    end.run(solver: solver)

    assert_equal ["ProjectsController#move"], report.verified.map(&:action)
    findings = report.findings.to_h { |finding| [finding.exposure.action, finding] }
    assert_empty findings.fetch("ProjectsController#archive").record_tenant.roles
    rename = findings.fetch("ProjectsController#rename")
    assert_predicate rename, :own_record?
    assert_empty rename.record_tenant.roles
  end
end
