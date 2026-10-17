# frozen_string_literal: true

require "test_helper"

# Decodes a real Alloy 6.2 run of the MediumClone example, captured in
# test/fixtures/medium_clone, so these tests need neither Java nor the jar.
class ReportTest < Minitest::Test
  def report
    analysis = load_example("medium_clone/hallmark.rb")
    receipt = Hallmark::Receipt.load(File.join(FIXTURES, "medium_clone"))
    Hallmark::Report.new(analysis, receipt)
  end

  def test_receipt_separates_counterexamples_from_checks_that_hold
    receipt = Hallmark::Receipt.load(File.join(FIXTURES, "medium_clone"))
    with_counterexample = receipt.commands.values.select(&:counterexample?).map(&:name)

    assert_equal %w[safe_UsersController_update_write_User safe_PostsController_update_write_Post].sort,
                 with_counterexample.sort
    assert_equal 6, receipt.commands.size
  end

  def test_instance_exposes_skolems_and_fields
    receipt = Hallmark::Receipt.load(File.join(FIXTURES, "medium_clone"))
    instance = receipt["safe_UsersController_update_write_User"].instance

    assert_equal "catalog/User$1", instance.skolem("$safe_UsersController_update_write_User_p")
    assert_equal "UserProfile$0", instance.skolem("$safe_UsersController_update_write_User_r")
    assert_equal ["catalog/User$0"], instance.field("UserProfile$0", "owner")
    assert_empty instance.field("catalog/User$1", "assigned")
  end

  def test_profile_bug_is_explained_in_app_terms
    finding = report.findings.find { |f| f.exposure.action == "UsersController#update" }

    assert_equal "User profiles", finding.pattern
    assert_equal "a signed-in User (User$1) holding no roles can update the User profile of User$0", finding.message
  end

  def test_missing_authentication_is_explained_in_app_terms
    finding = report.findings.find { |f| f.exposure.action == "PostsController#update" }

    assert_predicate finding, :anonymous?
    assert_equal "Authentication", finding.pattern
    assert_equal "an anonymous visitor can update a Post owned by User$0", finding.message
  end

  # Current-tenant confusion (M2) in a Gumroad-shaped store, from
  # test/fixtures/storefront.
  def storefront_report
    analysis = load_example("storefront/hallmark.rb")
    receipt = Hallmark::Receipt.load(File.join(FIXTURES, "storefront"))
    Hallmark::Report.new(analysis, receipt)
  end

  def test_instance_finds_sources_of_a_field
    receipt = Hallmark::Receipt.load(File.join(FIXTURES, "storefront"))
    instance = receipt["safe_LinksController_update_write_Link"].instance

    assert_equal ["catalog/Membership$1", "catalog/Membership$2"], instance.sources("member", "catalog/User$1")
    assert_equal ["catalog/Tenant$1"], instance.sources("user", "catalog/User$2")
    assert_empty instance.sources("member", "catalog/Anonymous$0")
  end

  def test_current_tenant_confusion_is_explained_in_app_terms
    finding = storefront_report.findings.fetch(0)

    assert_equal "LinksController#update", finding.exposure.action
    assert_predicate finding, :cross_tenant?
    assert_equal %w[admin marketing owner], finding.current_tenant.roles
    assert_empty finding.record_tenant.roles
    assert_equal "a signed-in User (User$2) holding roles admin, marketing, owner in the current tenant User$2 " \
                 "(their own) can update a Link (Link$0) in tenant User$1, where they hold no roles",
                 finding.message
    assert_match(/check that it belongs to the tenant the request acts for/, finding.hint)
  end

  def test_storefront_report_text
    report = storefront_report
    text = report.to_s

    assert_equal 1, report.exit_code
    assert_includes text, "FAIL  LinksController#update (write Link)"
    assert_includes text, "ok    Admin::LinksController#update (write Link)"
    assert_includes text, "1 counterexample in 3 checks."
  end

  def test_untenanted_findings_have_no_tenants
    finding = report.findings.fetch(0)

    assert_nil finding.current_tenant
    assert_nil finding.record_tenant
    refute_predicate finding, :cross_tenant?
  end

  def test_report_text_and_exit_code
    text = report.to_s

    assert_equal 1, report.exit_code
    assert_includes text, "FAIL  UsersController#update (write User)"
    assert_includes text, "ok    PostsController#show (read Post)"
    assert_includes text, "2 counterexamples in 6 checks."
  end
end
