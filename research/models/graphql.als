module graphql

-- Tenancy core (same shape as tenancy.als)
sig Org {}
abstract sig Principal {}
one sig Anonymous extends Principal {}
sig User extends Principal {}
abstract sig Role {}
one sig OrgAdmin, Member extends Role {}
sig Membership { user: one User, org: one Org, roles: set Role }
fact { all u: User, o: Org | lone m: Membership | m.user = u and m.org = o }
fun rolesIn[p: Principal, o: Org]: set Role { (user.p & org.o).roles }
pred member[p: Principal, o: Org] { some (user.p & org.o) }

-- Guards: what Assay extracted (guard) and what the mapping intends (policy)
abstract sig Guard {}
one sig NoCheck, LoggedIn, TenantMember, TenantAdmin, SelfOrAdmin extends Guard {}

abstract sig GType { guard: one Guard, policy: one Guard }   -- self.authorized?
sig NodeType in GType {}                                      -- implements Relay Node

sig Obj { gtype: one GType, tenant: one Org, represents: lone User }

abstract sig GField { src: one GType, dst: one GType, guard: one Guard, link: Obj -> Obj }
abstract sig Attr { on: one GType, guard: one Guard, policy: one Guard }   -- scalar fields
abstract sig RootList { returns: one GType, scope: one Guard }             -- scope_items

fact WellTyped {
  all f: GField | f.link in (gtype.(f.src)) -> (gtype.(f.dst))
  all f: GField, a, b: Obj | a -> b in f.link implies a.tenant = b.tenant
}

pred passes[g: Guard, p: Principal, o: Obj] {
  g = NoCheck
  or (g = LoggedIn and p in User)
  or (g = TenantMember and member[p, o.tenant])
  or (g = TenantAdmin and OrgAdmin in rolesIn[p, o.tenant])
  or (g = SelfOrAdmin and (o.represents = p or OrgAdmin in rolesIn[p, o.tenant]))
}

-- One resolver step: field check on the parent, then the child type's authorized?
fun step[p: Principal]: Obj -> Obj {
  { a, b: Obj | some f: GField |
      a -> b in f.link and passes[f.guard, p, a] and passes[b.gtype.guard, p, b] }
}
-- Entry points: scoped root lists, plus node(id:) for any Node type
fun roots[p: Principal]: set Obj {
  { o: Obj | some r: RootList | o.gtype = r.returns and passes[r.scope, p, o]
                                 and passes[o.gtype.guard, p, o] }
  + { o: Obj | o.gtype in NodeType and passes[o.gtype.guard, p, o] }
}
fun exposed[p: Principal]: set Obj { roots[p].*(step[p]) }

-- Generated from the app schema
one sig OrgT, ProjectT, InvoiceT, UserT extends GType {}
one sig OrgProjects, ProjectInvoices, ProjectOwner extends GField {}
one sig UserEmail extends Attr {}
one sig OrgsRoot extends RootList {}

pred schema {
  NodeType = ProjectT + UserT
  OrgProjects.src = OrgT and OrgProjects.dst = ProjectT and OrgProjects.guard = NoCheck
  ProjectInvoices.src = ProjectT and ProjectInvoices.dst = InvoiceT and ProjectInvoices.guard = NoCheck
  ProjectOwner.src = ProjectT and ProjectOwner.dst = UserT and ProjectOwner.guard = NoCheck
  OrgsRoot.returns = OrgT and OrgsRoot.scope = TenantMember
  UserEmail.on = UserT and UserEmail.policy = SelfOrAdmin
  OrgT.policy = TenantMember and ProjectT.policy = TenantMember
  InvoiceT.policy = TenantAdmin and UserT.policy = LoggedIn
}
pred extractedGuards {          -- what the code actually checks today
  OrgT.guard = TenantMember and ProjectT.guard = TenantMember
  InvoiceT.guard = NoCheck      -- G2: reachable through org.projects.invoices
  UserT.guard = NoCheck         -- G3: node(id:) on a User global ID
  UserEmail.guard = NoCheck     -- G1: email readable by any viewer of the User
}
pred fixedGuards {
  all t: GType | t.guard = t.policy
  UserEmail.guard = UserEmail.policy
}

pred objectsOk[t: GType] { all p: Principal, o: exposed[p] & gtype.t | passes[t.policy, p, o] }
pred emailOk {
  all p: Principal, o: exposed[p] & gtype.(UserEmail.on) |
    passes[UserEmail.guard, p, o] implies passes[UserEmail.policy, p, o]
}

G2_NestedInvoices:  check { schema and extractedGuards implies objectsOk[InvoiceT] } for 4
G3_NodeLookupUser:  check { schema and extractedGuards implies objectsOk[UserT] } for 4
G1_UserEmailField:  check { schema and extractedGuards implies emailOk } for 4
FixedSchema:        check { schema and fixedGuards implies
                            (all t: GType | objectsOk[t]) and emailOk } for 4
