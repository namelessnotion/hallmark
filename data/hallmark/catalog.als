module catalog

-- Hallmark access control pattern catalog, after Near and Jackson,
-- "Finding Security Bugs in Web Applications using a Catalog of
-- Access Control Patterns" (ICSE 2016).
--
-- Each pattern whitelists one common, intended kind of access. An
-- application exposure that no pattern allows is reported as a bug.
--
-- Tenancy is a dimension of every pattern, not one more pattern: when a
-- record lives in a tenant, roles count only if held in that tenant.

abstract sig Op {}
one sig Read, Write extends Op {}

abstract sig Principal {}
one sig Anonymous extends Principal {}
sig User extends Principal { assigned: set Role }   -- roles held outside any tenant

sig Role { inherits: set Role }          -- a senior role inherits its juniors
one sig Admin extends Role {}
sig PlatformRole in Role {}              -- intended access across every tenant

-- The account a record lives in and memberships are scoped to. When the
-- app's tenants are themselves users (a Gumroad seller), `user` is that user.
sig Tenant { user: lone User }

-- A user's roles in one tenant, never globally
sig Membership { member: one User, within: one Tenant, roles: set Role }
fact OneMembershipPerUserAndTenant {
  all u: User, t: Tenant | lone m: Membership | m.member = u and m.within = t
}

-- `ownerOutside` holds the ops its owner may perform without being a
-- member of its tenant (the ownership without membership pattern).
abstract sig Resource { owner: lone User, tenant: lone Tenant, ownerOutside: set Op }
sig Public in Resource {}

sig Grant { role: one Role, op: one Op, res: set Resource }

-- One user's explicit permission on one record, held outside any role or
-- tenant, such as a collaborator on another seller's product.
sig Permit { holder: one User, ops: set Op, target: one Resource }

fun effective[p: Principal]: set Role { p.assigned.*inherits }

fun membershipIn[p: Principal, t: Tenant]: set Membership { member.p & within.t }
pred memberOf[p: Principal, t: Tenant] { some membershipIn[p, t] }
fun rolesIn[p: Principal, t: Tenant]: set Role { membershipIn[p, t].roles.*inherits }
fun rolesAnywhere[p: Principal]: set Role { (member.p).roles.*inherits }

-- The roles that count for a record: those held in its tenant, or those held
-- outside any tenant when the record has none.
fun rolesFor[p: Principal, r: Resource]: set Role {
  some r.tenant implies rolesIn[p, r.tenant] else effective[p]
}

pred authenticated[p: Principal] { p in User }

-- A guard with no condition at all
pred unguarded {}

-- The Admin role held outside any tenant (the guard `admin`)
pred isAdmin[p: Principal] { Admin in effective[p] }

-- Pattern: ownership. A signed-in user may read and write what they own,
-- while they remain a member of the record's tenant.
pred owns[p: Principal, r: Resource] {
  authenticated[p] and r.owner = p and (no r.tenant or memberOf[p, r.tenant])
}

-- Pattern: ownership without membership. For the ops a record's mapping
-- names, its signed-in owner may act on it without being a member of its
-- tenant, such as a card grant an organization gave someone outside its
-- team.
pred ownsOutsideTenant[p: Principal, o: Op, r: Resource] {
  authenticated[p] and r.owner = p and o in r.ownerOutside
}

-- Pattern: public objects. Anyone may read a public record.
pred publicRead[o: Op, r: Resource] { o = Read and r in Public }

-- Pattern: administrators. The Admin role may do anything to the records
-- of the tenant it is held in (or anything at all, held outside tenants).
pred administers[p: Principal, r: Resource] { Admin in rolesFor[p, r] }

-- Pattern: platform staff. A declared platform role may do anything in
-- any tenant, such as the app vendor's support staff.
pred platformStaff[p: Principal] { some effective[p] & PlatformRole }

-- Pattern: explicit permission. A grant to one of the user's roles in the
-- record's tenant.
pred granted[p: Principal, o: Op, r: Resource] {
  authenticated[p]
  some g: Grant | g.role in rolesFor[p, r] and g.op = o and r in g.res
}

-- Pattern: explicit permission on a record. A user may perform the ops a
-- permit on that record gives them.
pred permitted[p: Principal, o: Op, r: Resource] {
  some x: Permit | x.holder = p and x.target = r and o in x.ops
}

-- User profiles are modeled as resources owned by the user they describe,
-- so the ownership pattern covers "users may edit their own profile".

pred allowed[p: Principal, o: Op, r: Resource] {
  owns[p, r] or ownsOutsideTenant[p, o, r] or publicRead[o, r] or administers[p, r] or platformStaff[p]
    or granted[p, o, r] or permitted[p, o, r]
}

-- Pattern: public actions. An action the app means for everyone, such as
-- a public donation page, or for every signed-in user (SPACE's
-- authentication pattern). Unlike the patterns above it belongs to one
-- action, not to a kind of record, so only that action's check reads it:
-- the principal is in its audience (Principal for everyone, User for
-- signed-in users), on the records the action covers.
pred publicAction[p: Principal, audience: set Principal] { p in audience }

-- Structural checks over the application's role configuration
assert NoHierarchyCycles { no r: Role | r in r.^inherits }

sig Conflict { a, b: one Role }                 -- separation-of-duty pairs
assert StaticSoD { no u: User, c: Conflict | c.a + c.b in effective[u] }

sig CanAssign { by: one Role, gives: one Role }  -- who may hand out which role
assert NoEscalationByAssignment {
  all u: User, c: CanAssign |
    c.by in effective[u] implies c.gives.*inherits in effective[u]
}
