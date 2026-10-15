module tenancy

abstract sig Op {}
one sig Read, Write extends Op {}

sig Org {}

abstract sig Principal {}
one sig Anonymous extends Principal {}
sig User extends Principal {}

sig Role { inherits: set Role }
one sig OrgAdmin, Member extends Role {}

-- A user holds roles per organization, never globally
sig Membership { user: one User, org: one Org, roles: set Role }
fact OneMembershipPerUserAndOrg {
  all u: User, o: Org | lone m: Membership | m.user = u and m.org = o
}

-- Rolify-style grants that are NOT tied to one org instance
sig ScopedGrant { holder: one User, role: one Role, scope: one Scope }
abstract sig Scope {}
one sig Global, OrgClass extends Scope {}   -- add_role :x  /  add_role :x, Organization

abstract sig Resource { tenant: one Org, owner: lone User }

fun membershipIn[p: Principal, o: Org]: set Membership { user.p & org.o }
pred member[p: Principal, o: Org] { some membershipIn[p, o] }
fun rolesIn[p: Principal, o: Org]: set Role { membershipIn[p, o].roles.*inherits }
fun rolesAnywhere[p: Principal]: set Role { (user.p).roles.*inherits }

sig Grant { role: one Role, op: one Op, res: set Resource }

-- Tenant-aware catalog: every pattern is evaluated inside the record's org
pred owns[p: Principal, r: Resource]          { member[p, r.tenant] and r.owner = p }
pred orgAdmin[p: Principal, r: Resource]      { OrgAdmin in rolesIn[p, r.tenant] }
pred granted[p: Principal, o: Op, r: Resource] {
  some g: Grant | g.role in rolesIn[p, r.tenant] and g.op = o and r in g.res
}
pred allowed[p: Principal, o: Op, r: Resource] {
  owns[p, r] or orgAdmin[p, r] or granted[p, o, r]
}

sig Project extends Resource {}

-- T1. Unscoped role check: user.memberships.exists?(role: :admin)
pred projects_destroy_unscoped[p: Principal, r: Project] { OrgAdmin in rolesAnywhere[p] }
assert ProjectsDestroyUnscoped {
  all p: Principal, r: Project | projects_destroy_unscoped[p, r] implies allowed[p, Write, r]
}

-- T2. Current-org confusion: admin of Current.organization, record loaded by id only
pred projects_update_ctx[p: Principal, cur: Org, r: Project] { OrgAdmin in rolesIn[p, cur] }
pred projects_update_ctx_fixed[p: Principal, cur: Org, r: Project] {
  OrgAdmin in rolesIn[p, cur] and r.tenant = cur
}
assert ProjectsUpdateCtx {
  all p: Principal, cur: Org, r: Project | projects_update_ctx[p, cur, r] implies allowed[p, Write, r]
}
assert ProjectsUpdateCtxFixed {
  all p: Principal, cur: Org, r: Project | projects_update_ctx_fixed[p, cur, r] implies allowed[p, Write, r]
}

-- T3. Ownership outlives membership: SPACE-style guard record.owner == user
pred projects_edit_owner_only[p: Principal, r: Project] { r.owner = p }
assert ProjectsEditOwnerOnly {
  all p: Principal, r: Project | projects_edit_owner_only[p, r] implies allowed[p, Write, r]
}

-- T4. Invitations: admin of the current org invites into an org taken from params
sig Invite { by: one User, into: one Org, gives: one Role }
pred invites_create[p: Principal, cur: Org, i: Invite] { OrgAdmin in rolesIn[p, cur] and i.by = p }
assert InvitesStayInAdminsOrg {
  all p: Principal, cur: Org, i: Invite | invites_create[p, cur, i] implies OrgAdmin in rolesIn[p, i.into]
}

-- T5. Index scope spans every org the user belongs to, not the current one
fun projects_index_scope[p: Principal, cur: Org]: set Project { { r: Project | member[p, r.tenant] } }
assert IndexStaysInCurrentOrg {
  all p: Principal, cur: Org | projects_index_scope[p, cur].tenant in cur
}

-- T6. Rolify grant at the wrong scope reaches every org (no strict mode)
pred rolify_admin[p: Principal, o: Org] {
  OrgAdmin in rolesIn[p, o]
  or (some g: ScopedGrant | g.holder = p and g.role = OrgAdmin)   -- global or class-level
}
assert RolifyAdminStaysInOrg {
  all p: Principal, o: Org | rolify_admin[p, o] implies member[p, o]
}

check ProjectsDestroyUnscoped for 4
check ProjectsUpdateCtx for 4
check ProjectsUpdateCtxFixed for 4
check ProjectsEditOwnerOnly for 4
check InvitesStayInAdminsOrg for 4
check IndexStaysInCurrentOrg for 4
check RolifyAdminStaysInOrg for 4
check ProjectsUpdateCtx for 4 but 1 Org
