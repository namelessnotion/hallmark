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
    assert_includes model.source,
                    "pred allows_Admin_PostsController_destroy_write[p: Principal, r: Post] { Role_moderator in effective[p] }"
    assert_includes model.source, "implies allowed[p, Write, r]"
    assert_includes model.source, "check safe_Admin_PostsController_destroy_write for 4"
    assert_equal ["safe_Admin_PostsController_destroy_write"], model.checks.keys
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
      build { map { resource "Post"; grant :moderator, :destroy, "Post" } }
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

  def test_scope_below_two_is_rejected
    analysis = Hallmark::Analysis.build("Test") { map { resource "Post" } }
    assert_raises(Hallmark::ConfigurationError) { Hallmark::ModelBuilder.new(analysis, scope: 1) }
  end
end
