# frozen_string_literal: true

require "test_helper"

class ModelBuilderTest < Minitest::Test
  def build(scope: 5, &)
    analysis = Hallmark::Analysis.build("Test", &)
    Hallmark::ModelBuilder.new(analysis, scope: scope).build
  end

  def test_opens_the_catalog
    model = build do
      map { resource "Post", owner: :author }
      writes "PostsController#update", "Post", guard: logged_in & owner
    end

    assert_match(/^open catalog$/, model.source)
  end

  def test_owned_resource_gets_an_owner_and_is_never_public_by_default
    model = build do
      map { resource "Post", owner: :author }
      writes "PostsController#update", "Post", guard: logged_in & owner
    end

    assert_includes model.source, "sig Post extends Resource {}"
    assert_includes model.source, "fact Post_has_owner { all r: Post | one r.owner }"
    assert_includes model.source, "fact Post_never_public { no Post & Public }"
  end

  def test_public_options
    model = build do
      map do
        resource "Article", public_if: :published?
        resource "Page", public_if: true
      end
      reads "ArticlesController#show", "Article", guard: public_record
      reads "PagesController#show", "Page", guard: none
    end

    refute_match(/Article_(never|always)_public/, model.source)
    assert_includes model.source, "fact Page_always_public { Page in Public }"
    assert_includes model.source, "fact Article_has_no_owner { no Article <: owner }"
  end

  def test_profiles_belong_to_exactly_one_user
    model = build do
      map { resource "User", kind: :profile }
      writes "UsersController#update", "User", guard: logged_in
    end

    assert_includes model.source, "sig UserProfile extends Resource {}"
    assert_includes model.source, "all r: UserProfile | one r.owner"
    assert_includes model.source, "all u: User | lone (UserProfile <: owner).u"
  end

  def test_names_that_clash_with_the_catalog_are_renamed
    model = build do
      map { resource "Grant", owner: :issuer }
      reads "GrantsController#show", "Grant", guard: owner
    end

    assert_includes model.source, "sig GrantRecord extends Resource {}"
  end

  def test_each_exposure_becomes_an_assertion_and_a_check
    model = build(scope: 4) do
      map { resource "Post", owner: :author }
      writes "Admin::PostsController#destroy", "Post", guard: role(:moderator)
    end

    assert_includes model.source, "one sig Role_moderator extends Role {}"
    assert_includes model.source, "pred allows_Admin_PostsController_destroy_write_Post[p: Principal, r: Post] " \
                                  "{ Role_moderator in effective[p] }"
    assert_includes model.source, "implies allowed[p, Write, r]"
    assert_includes model.source, "check safe_Admin_PostsController_destroy_write_Post for 4"
    assert_equal ["safe_Admin_PostsController_destroy_write_Post"], model.checks.keys
  end

  def test_grants_become_fixed_grant_atoms
    model = build do
      map do
        resource "Post", owner: :author
        resource "Report"
        grant :moderator, :write, "Post"
        grant :auditor, :read, "Report"
      end
      writes "ModerationController#hide", "Post", guard: role(:moderator)
    end

    assert_includes model.source, "one sig Role_auditor extends Role {}"
    assert_includes model.source, "one sig Role_moderator extends Role {}"
    assert_includes model.source, "one sig Grant_moderator_write_Post extends Grant {}"
    assert_includes model.source,
                    "Grant_moderator_write_Post.role = Role_moderator and Grant_moderator_write_Post.op = Write " \
                    "and Grant_moderator_write_Post.res = Post"
    assert_includes model.source, "sig Report extends Resource {}" # used by a grant, so declared
  end

  def test_grants_validate_op_and_resource
    assert_raises(Hallmark::ConfigurationError) do
      build do
        map do
          resource "Post"
          grant :moderator, :destroy, "Post"
        end
      end
    end
    assert_raises(Hallmark::ConfigurationError) do
      build { map { grant :moderator, :write, "Post" } }
    end
  end

  def test_unmapped_resources_are_rejected
    error = assert_raises(Hallmark::ConfigurationError) do
      build { writes "PostsController#update", "Post", guard: logged_in }
    end
    assert_match(/resource Post is not mapped/, error.message)
  end

  def test_models_without_a_tenant_have_no_tenants
    model = build do
      map { resource "Post", owner: :author }
      writes "PostsController#update", "Post", guard: logged_in & owner
    end

    assert_includes model.source, "fact no_tenants { no Tenant and no Membership }"
    assert_includes model.source, "fact platform_roles { no PlatformRole }"
    assert_includes model.source, "pred allows_PostsController_update_write_Post[p: Principal, r: Post]"
    refute_match(/tenant \{|cur: Tenant/, model.source)
  end

  def storefront(scope: 5)
    build(scope: scope) do
      map do
        tenant "User", membership: "TeamMembership", member: :user, roles: :role, self: :owner
        current_tenant :seller
        platform_role :staff
        resource "Link", tenant: :user
        resource "Page"
        grant :admin, :write, "Link"
      end
      writes "LinksController#update", "Link", guard: role(:admin, tenant: :current)
      reads "PagesController#show", "Page", guard: none
    end
  end

  def test_tenant_aware_guards_see_the_current_tenant
    source = storefront.source

    assert_includes source, "pred allows_LinksController_update_write_Link[p: Principal, cur: Tenant, r: Link] " \
                            "{ Role_admin in rolesIn[p, cur] }"
    assert_includes source, "all p: Principal, cur: Tenant, r: Link | " \
                            "allows_LinksController_update_write_Link[p, cur, r] implies allowed[p, Write, r]"
    assert_includes source, "-- current tenant: seller"
  end

  # Without `permits:` nobody holds an explicit permission.
  def test_permits_exist_only_where_the_mapping_declares_them
    assert_includes storefront.source, "fact no_permits { no Permit }"

    analysis = Hallmark::Analysis.build("Collaborators") do
      map do
        tenant "User", membership: "TeamMembership", self: :owner
        resource "Link", tenant: :user, permits: :collaborator_for?
        resource "Page"
      end
      writes "LinksController#update", "Link", guard: permitted | (role(:owner, tenant: :current) & in_current_tenant)
      reads "PagesController#show", "Page", guard: none
    end
    source = Hallmark::ModelBuilder.new(analysis).source

    assert_includes source, "-- Link (tenant: user, explicit permissions)"
    assert_includes source, "fact Page_has_no_permits { no target.Page }"
    refute_includes source, "fact no_permits"
    assert_includes source, "{ (permitted[p, Write, r] or (Role_owner in rolesIn[p, cur] and r.tenant = cur)) }"
  end

  def test_roles_are_the_declared_ones_with_no_hierarchy
    source = storefront.source

    assert_includes source, "fact declared_roles { Role = Admin + Role_admin + Role_owner + Role_staff " \
                            "and no inherits }"
    assert_includes source, "fact no_administrators { no assigned.Admin and no roles.Admin }"
  end

  def test_records_live_in_one_tenant_or_none
    source = storefront.source

    assert_includes source, "-- Link (tenant: user)"
    assert_includes source, "fact Link_in_one_tenant { all r: Link | one r.tenant }"
    assert_includes source, "fact Page_has_no_tenant { no Page <: tenant }"
  end

  # Forem: an article lives in an organization or in none.
  def test_records_with_an_optional_tenant_live_in_at_most_one
    model = build do
      map do
        tenant "Organization", membership: "OrganizationMembership"
        resource "Article", owner: :user, tenant: :organization, tenant_optional: true
      end
      writes "ArticlesController#update", "Article", guard: logged_in & owner
    end

    assert_includes model.source, "fact Article_in_at_most_one_tenant { all r: Article | lone r.tenant }"
  end

  def test_outside_tenants_becomes_no_tenant_on_the_record
    model = build do
      map do
        tenant "Organization", membership: "OrganizationMembership"
        resource "Article", owner: :user, tenant: :organization, tenant_optional: true
      end
      writes "ArticlesController#update", "Article",
             guard: owner & (outside_tenants | role(:admin, tenant: :record))
    end

    assert_includes model.source, "(r.owner = p and (no r.tenant or Role_admin in rolesIn[p, r.tenant]))"
  end

  def test_tenants_that_are_users_hold_their_self_role_in_themselves
    source = storefront.source

    assert_includes source, "all t: Tenant | one t.user"
    assert_includes source, "all t: Tenant | some m: membershipIn[t.user, t] | Role_owner in m.roles"
    assert_includes source, "all m: Membership | Role_owner in m.roles implies m.member = m.within.user"
    assert_includes source, "one sig Role_owner extends Role {}"
  end

  def test_only_platform_roles_are_held_outside_tenants
    source = storefront.source

    assert_includes source, "fact roles_outside_tenants {\n  all u: User | u.assigned in PlatformRole\n  " \
                            "no Membership.roles & PlatformRole\n}"
    assert_includes source, "fact platform_roles { PlatformRole = Role_staff }"
  end

  def test_tenants_that_are_not_users
    model = build do
      map do
        tenant "Organization", membership: "Membership", member: :user, roles: :role
        resource "Project", tenant: :organization, owner: :creator
      end
      writes "ProjectsController#update", "Project", guard: role(:admin, tenant: :any)
    end

    assert_includes model.source, "fact tenants_are_not_users { no Tenant.user }"
    assert_includes model.source, "{ Role_admin in rolesAnywhere[p] }"
    assert_includes model.source, "sig Project extends Resource {}"
  end

  # Scope 2 leaves Anonymous and one User, so tenants that are users would
  # collapse to one and current-tenant confusion could not be represented.
  def test_scope_leaves_room_for_two_tenants
    assert_includes storefront(scope: 2).source, "check safe_LinksController_update_write_Link for 2 but 3 Principal"
    assert_includes storefront(scope: 3).source, "check safe_LinksController_update_write_Link for 3\n"
  end

  def test_tenancy_names_that_clash_with_the_catalog_are_renamed
    model = build do
      map { resource "Membership", owner: :user }
      reads "MembershipsController#show", "Membership", guard: owner
    end

    assert_includes model.source, "sig MembershipRecord extends Resource {}"
  end

  def test_scope_below_two_is_rejected
    analysis = Hallmark::Analysis.build("Test") { map { resource "Post" } }
    assert_raises(Hallmark::ConfigurationError) { Hallmark::ModelBuilder.new(analysis, scope: 1) }
  end
end
