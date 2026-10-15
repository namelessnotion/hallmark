# frozen_string_literal: true

require "test_helper"

# Phase 0 exit gate: reproduce the MediumClone bugs that Near and Jackson walk
# through in the SPACE paper, using the real Alloy jar.
class MediumCloneTest < Minitest::Test
  def test_reproduces_both_bugs_from_the_paper
    solver = require_solver!
    report = load_example("medium_clone/hallmark.rb").run(solver: solver)

    failing = report.findings.to_h { |finding| [finding.exposure.action, finding] }
    assert_equal %w[PostsController#update UsersController#update], failing.keys.sort

    # Figure 2(a): a user can update another user's profile
    profile = failing.fetch("UsersController#update")
    refute_predicate profile, :anonymous?
    refute_predicate profile, :own_record?
    assert_equal "User profiles", profile.pattern

    # Figure 2(b): an unauthenticated user can update any post
    post = failing.fetch("PostsController#update")
    assert_predicate post, :anonymous?
    assert_equal "Authentication", post.pattern
  end

  def test_fixed_version_has_no_counterexamples
    solver = require_solver!
    report = load_example("medium_clone/hallmark_fixed.rb").run(solver: solver)

    assert_predicate report, :clean?
    assert_equal 6, report.verified.size
  end

  # Fixing only the sign-in check leaves the ownership bug, which the paper
  # notes is "forgotten across the entire application codebase".
  def test_sign_in_alone_does_not_fix_post_updates
    solver = require_solver!
    analysis = Hallmark::Analysis.build("MediumClone (sign-in only)") do
      map { resource "Post", owner: :user, public_if: true }
      writes "PostsController#update", "Post", guard: logged_in
    end

    finding = analysis.run(solver: solver).findings.fetch(0)
    refute_predicate finding, :anonymous?
    refute_predicate finding, :own_record?
    assert_equal "Ownership", finding.pattern
  end

  def test_roles_and_admins_are_honored
    solver = require_solver!
    analysis = Hallmark::Analysis.build("Moderation") do
      map { resource "Post", owner: :user }
      writes "Admin::PostsController#update", "Post", guard: admin
      writes "ModerationController#hide", "Post", guard: role(:moderator)
    end

    report = analysis.run(solver: solver)
    assert_equal ["Admin::PostsController#update"], report.verified.map(&:action)

    finding = report.findings.fetch(0)
    assert_equal "ModerationController#hide", finding.exposure.action
    assert_equal "Explicit permission", finding.pattern
    assert_equal ["moderator"], finding.roles
    assert_includes finding.hint, 'grant :moderator, :write, "Post"'
  end

  def test_declared_grants_make_role_checks_pass
    solver = require_solver!
    analysis = Hallmark::Analysis.build("Moderation with grant") do
      map do
        resource "Post", owner: :user
        grant :moderator, :write, "Post"
      end
      writes "ModerationController#hide", "Post", guard: role(:moderator)
      writes "ModerationController#pin", "Post", guard: role(:editor)
    end

    report = analysis.run(solver: solver)
    assert_equal ["ModerationController#hide"], report.verified.map(&:action)
    assert_equal ["ModerationController#pin"], report.findings.map { |f| f.exposure.action }
  end
end
