# frozen_string_literal: true

require "test_helper"

class MappingTest < Minitest::Test
  # Stand-ins for application classes, to map by constant
  Seller = Class.new
  TeamMembership = Class.new
  Product = Class.new

  def analysis(&)
    Hallmark::Analysis.build("Test", &)
  end

  def test_class_constants_and_strings_normalize_to_the_class_name
    mapping = analysis do
      map do
        principal Seller
        tenant Seller, membership: TeamMembership, self: :owner
        resource Product, tenant: :seller
        grant :owner, :write, Product
      end
      writes "ProductsController#update", Product, guard: role(:owner, tenant: :current) & in_current_tenant
    end.mapping

    assert_equal "MappingTest::Seller", mapping.principal_name
    assert_equal "MappingTest::Seller", mapping.tenancy.name
    assert_equal "MappingTest::TeamMembership", mapping.tenancy.membership
    assert_equal ["MappingTest::Product"], mapping.resources.keys
    assert_equal "MappingTest::Product", mapping.grants.first.resource
    assert_same mapping.fetch(Product), mapping.fetch("MappingTest::Product")
  end

  def test_tenant_options
    tenancy = analysis do
      map { tenant "Organization", membership: "Membership", member: :account, roles: :level }
    end.mapping.tenancy

    assert_equal "Organization", tenancy.name
    assert_equal :account, tenancy.member
    assert_equal :level, tenancy.roles
    refute_predicate tenancy, :principals?
  end

  def test_self_marks_tenants_as_principals
    tenancy = analysis { map { tenant "User", self: :owner } }.mapping.tenancy

    assert_predicate tenancy, :principals?
    assert_equal "owner", tenancy.self_role
  end

  def test_self_needs_the_tenant_class_to_be_the_principal_class
    error = assert_raises(Hallmark::ConfigurationError) do
      analysis { map { tenant "Organization", self: :owner } }
    end
    assert_match(/needs the tenant class to be the principal class/, error.message)
  end

  def test_one_tenant_class_only
    assert_raises(Hallmark::ConfigurationError) do
      analysis do
        map do
          tenant "Organization"
          tenant "Group"
        end
      end
    end
  end

  def test_a_tenanted_resource_needs_a_tenant
    error = assert_raises(Hallmark::ConfigurationError) do
      analysis { map { resource "Project", tenant: :organization } }
    end
    assert_match(/resource Project has a tenant, but the map block declares no `tenant`/, error.message)
  end

  def test_current_tenant_and_platform_roles
    mapping = analysis do
      map do
        tenant "Organization"
        current_tenant :seller
        platform_role :staff, "billing"
        platform_role :staff
      end
    end.mapping

    assert_equal :seller, mapping.current_tenant_source
    assert_equal %w[staff billing], mapping.platform_roles
  end

  def test_anonymous_classes_cannot_be_mapped
    assert_raises(Hallmark::ConfigurationError) { analysis { map { resource Class.new } } }
  end

  def test_permitted_needs_a_resource_mapped_with_permits
    error = assert_raises(Hallmark::ConfigurationError) do
      Hallmark::Analysis.build("Test") do
        map { resource "Post", owner: :user }
        writes "PostsController#update", "Post", guard: permitted
      end
    end
    assert_match(/reads explicit permissions, but Post is mapped without `permits:`/, error.message)
  end

  def test_guards_cannot_read_tenants_without_a_tenant
    error = assert_raises(Hallmark::ConfigurationError) do
      analysis do
        map { resource "Post" }
        writes "PostsController#update", "Post", guard: in_current_tenant
      end
    end
    assert_match(/reads tenants, but the map block declares no `tenant`/, error.message)
  end

  # With a tenant, users hold only platform roles outside tenants, so a role
  # check without `tenant:` would never pass and the check would hold vacuously.
  def test_tenant_aware_guards_check_only_platform_roles_outside_tenants
    error = assert_raises(Hallmark::ConfigurationError) do
      analysis do
        map do
          tenant "Organization"
          resource "Project", tenant: :organization
        end
        writes "ProjectsController#update", "Project", guard: role(:admin) | admin
      end
    end
    assert_match(/checks admin, Admin outside any tenant/, error.message)
  end

  def test_platform_roles_are_checked_outside_tenants
    exposure = analysis do
      map do
        tenant "Organization"
        platform_role :staff
        resource "Project", tenant: :organization
      end
      writes "Admin::ProjectsController#update", "Project", guard: role(:staff)
    end.exposures.first

    assert_equal ["staff"], exposure.guard.roles_outside_tenants
  end

  # A mapping with one declaration of each kind, and a copy extended with one more.
  def original_and_extended_copy
    original = Hallmark::Mapping.new
    original.instance_eval do
      resource "Link"
      grant :admin, :read, "Link"
      rule "LinkPolicy", :show?, op: :read
      platform_role :staff
      allow_unchecked "PagesController#home"
    end
    copy = original.dup
    copy.instance_eval do
      resource "Shop"
      grant :admin, :write, "Shop"
      rule "ShopPolicy", :update?, op: :write
      platform_role :support
      allow_unchecked "PagesController#about"
    end
    [original, copy]
  end

  def test_extending_a_copy_leaves_the_source_unchanged
    original, = original_and_extended_copy

    assert_equal ["Link"], original.resources.keys
    assert_equal ["Link"], original.grants.map(&:resource)
    assert_equal ["LinkPolicy#show?"], original.rules.keys
    assert_equal ["staff"], original.platform_roles
    assert_equal ["PagesController#home"], original.unchecked_allowed
  end

  def test_a_copy_keeps_the_source_declarations_and_adds_its_own
    _, copy = original_and_extended_copy

    assert_equal %w[Link Shop], copy.resources.keys
    assert_equal %w[Link Shop], copy.grants.map(&:resource)
    assert_equal %w[LinkPolicy#show? ShopPolicy#update?], copy.rules.keys
    assert_equal %w[staff support], copy.platform_roles
    assert_equal %w[PagesController#home PagesController#about], copy.unchecked_allowed
  end

  def test_analyze_starts_from_a_copy_of_the_configured_mapping
    Hallmark.configure { |config| config.map { resource "Link" } }
    configured = Hallmark.configuration.mapping

    analysis = Hallmark.analyze do
      map do
        resource "Shop"
        grant :admin, :write, "Shop"
      end
    end

    assert_same configured, Hallmark.configuration.mapping
    assert_equal ["Link"], configured.resources.keys
    assert_empty configured.grants
    assert_equal %w[Link Shop], analysis.mapping.resources.keys
    assert_equal ["Shop"], analysis.mapping.grants.map(&:resource)
  end

  def test_two_analyses_each_extend_the_configured_mapping
    Hallmark.configure { |config| config.map { resource "Link" } }

    first = Hallmark.analyze("First") { map { resource "Shop" } }
    second = Hallmark.analyze("Second") { map { resource "Shop" } }

    assert_equal %w[Link Shop], first.mapping.resources.keys
    assert_equal %w[Link Shop], second.mapping.resources.keys
    assert_equal ["Link"], Hallmark.configuration.mapping.resources.keys
  end
end
