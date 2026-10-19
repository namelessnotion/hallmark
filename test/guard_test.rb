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

  # An explicit permission is for the exposure's op, so rendering needs it.
  def test_permitted_reads_the_exposures_op
    guard = permitted | role(:admin, tenant: :current)

    assert_equal "(permitted[p, Write, r] or Role_admin in rolesIn[p, cur])", guard.to_alloy("Write")
    assert_equal "(permitted | role(:admin, tenant: :current))", guard.to_s
    assert_predicate guard, :permits?
    refute_predicate logged_in, :permits?
    assert_raises(ArgumentError) { permitted.to_alloy }
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

  def test_role_checks_say_which_tenant_they_look_in
    assert_equal "Role_admin in rolesIn[p, cur]", role(:admin, tenant: :current).to_alloy
    assert_equal "Role_admin in rolesIn[p, r.tenant]", role(:admin, tenant: :record).to_alloy
    assert_equal "Role_admin in rolesAnywhere[p]", role(:admin, tenant: :any).to_alloy
    assert_equal "r.tenant = cur", in_current_tenant.to_alloy
    assert_equal "(role(:admin, tenant: :current) & in_current_tenant)",
                 (role(:admin, tenant: :current) & in_current_tenant).to_s
  end

  def test_outside_tenants_asks_for_a_record_with_no_tenant
    guard = owner & outside_tenants

    assert_equal "no r.tenant", outside_tenants.to_alloy
    assert_equal "(owner & outside_tenants)", guard.to_s
    assert_equal %i[record], guard.tenants
    assert_predicate guard, :outside_tenants?
    refute_predicate owner, :outside_tenants?
  end

  def test_unknown_role_tenants_are_rejected
    assert_raises(ArgumentError) { role(:admin, tenant: :organization) }
  end

  def test_tenant_terms_are_collected_through_operators
    guard = (role(:admin, tenant: :current) | role(:owner, tenant: :record)) & ~in_current_tenant

    assert_equal %i[current record], guard.tenants
    assert_empty (logged_in & role(:staff)).tenants
  end

  def test_roles_outside_tenants
    guard = role(:staff) | admin | role(:admin, tenant: :current)

    assert_equal %w[staff Admin], guard.roles_outside_tenants
    assert_equal %w[staff admin], guard.roles
  end

  def test_combining_with_a_non_guard_is_rejected
    assert_raises(ArgumentError) { logged_in & true }
  end
end
