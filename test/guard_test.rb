# frozen_string_literal: true

require "test_helper"

class GuardTest < Minitest::Test
  include Hallmark::Guard::DSL

  def test_atoms_render_to_catalog_predicates
    assert_equal "unguarded", none.to_alloy
    assert_equal "authenticated[p]", logged_in.to_alloy
    assert_equal "r.owner = p", owner.to_alloy
    assert_equal "isAdmin[p]", admin.to_alloy
    assert_equal "r in Public", public_record.to_alloy
    assert_equal "Role_editor in effective[p]", role(:editor).to_alloy
  end

  def test_operators_compose_with_explicit_parentheses
    guard = logged_in & (owner | ~public_record)
    assert_equal "(authenticated[p] and (r.owner = p or (not r in Public)))", guard.to_alloy
    assert_equal "(logged_in & (owner | ~public_record))", guard.to_s
  end

  def test_roles_are_collected_through_operators
    guard = role(:editor) | (role(:approver) & ~role(:editor))
    assert_equal %w[editor approver], guard.roles
  end

  def test_guards_are_values
    assert_equal logged_in & owner, logged_in & owner
    refute_equal logged_in & owner, owner & logged_in
    assert_predicate logged_in, :frozen?
  end

  def test_combining_with_a_non_guard_is_rejected
    assert_raises(ArgumentError) { logged_in & true }
  end
end
