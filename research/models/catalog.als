module catalog

abstract sig Op {}
one sig Read, Write extends Op {}

abstract sig Principal {}
one sig Anonymous extends Principal {}
sig User extends Principal { assigned: set Role }

sig Role { inherits: set Role }          -- a senior role inherits its juniors
one sig Admin extends Role {}

abstract sig Resource { owner: lone User }
sig Public in Resource {}

sig Grant { role: one Role, op: one Op, res: set Resource }

fun effective[p: Principal]: set Role { p.assigned.*inherits }

pred authenticated[p: Principal] { p in User }

-- The catalog: each pattern whitelists one common, intended access
pred owns[p: Principal, r: Resource]                 { authenticated[p] and r.owner = p }
pred publicRead[o: Op, r: Resource]                  { o = Read and r in Public }
pred isAdmin[p: Principal]                           { Admin in effective[p] }
pred granted[p: Principal, o: Op, r: Resource] {
  authenticated[p]
  some g: Grant | g.role in effective[p] and g.op = o and r in g.res
}

pred allowed[p: Principal, o: Op, r: Resource] {
  owns[p, r] or publicRead[o, r] or isAdmin[p] or granted[p, o, r]
}

-- Structural checks over the app's real role config
assert NoHierarchyCycles { no r: Role | r in r.^inherits }

sig Conflict { a, b: one Role }               -- separation of duty pairs
assert StaticSoD { no u: User, c: Conflict | c.a + c.b in effective[u] }

sig CanAssign { by: one Role, gives: one Role } -- who may hand out which role
assert NoEscalationByAssignment {
  all u: User, c: CanAssign |
    c.by in effective[u] implies c.gives.*inherits in effective[u]
}
