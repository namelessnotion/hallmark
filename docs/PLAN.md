# Hallmark: Alloy-backed RBAC analysis for Ruby

Oct 14, 2026 · Anthony Byram

Exported from the planning doc on Oct 15, 2026, after phase 0 shipped. Keep this file current as the design changes; `CLAUDE.md` summarizes what is built versus planned.

## Summary

Hallmark is a Ruby gem that turns an app's role-based authorization (roles, grants, ownership rules, and the decisions it actually makes at run time) into an Alloy 6 model, then asks the Alloy Analyzer for counterexamples: a concrete user, role and record where an action is allowed that no intended access pattern allows.

The recommended direction:

- **Build on SPACE, change the fact source.** Near and Jackson's SPACE (ICSE 2016) already proved the idea: a small catalog of access control patterns in Alloy found 23 real bugs in Rails apps. Hallmark keeps the catalog and swaps fragile symbolic execution for policy-code extraction plus runtime observation.
- **Alloy 6.2 in a JVM sidecar.** The gem manages a long-lived Java process speaking JSON over stdio, so it works on CRuby. An in-process JRuby 10 backend comes later behind the same interface.
- **Never solve on the request path.** Requests only append cheap authorization events; verification runs in CI, in a staging shadow mode, or in a sampled background worker.
- **First target:** Rails apps (any version) using Pundit, Action Policy or DeclarativePolicy, with roles from Rolify, an enum column, or per-organization memberships, where one user can hold different roles in several orgs. graphql-ruby schemas, including field-level authorization, are in v1 too.

**Name:** Hallmark. A hallmark is the mark an assay office strikes to certify what an alloy is made of. Here the assay is the bounded search, and the hallmark is its report: which pattern each exposure matches, and where one matches none. The evidence going in is stamps, the deduplicated authorization decisions the app was seen to make. `CONTEXT.md` defines these terms. "Assay" (already a RubyGems assertion library) and "Warden" (the Rack auth gem Devise sits on) were ruled out.

## Threat catalog

Hallmark v1 targets fifteen RBAC failure modes; the first five are the SPACE catalog's, where missing authentication alone accounted for 10 of SPACE's 23 confirmed bugs.

| # | Vulnerability | What it looks like in a Rails app | Fact source |
| --- | --- | --- | --- |
| 1 | Missing authentication | `update` skips the `signed_in` filter that `edit` has; an anonymous POST works | Runtime + routes |
| 2 | Missing ownership check (IDOR) | `Post.find(params[:id])` then update, no `post.user == current_user` | Runtime + policy code |
| 3 | Profile tampering | One user can update another user's profile or settings | Runtime |
| 4 | Over-broad public exposure | A resource type marked public leaks a private field or draft state | Runtime + serializers |
| 5 | Explicit-permission bypass | A share or membership row is checked on `show` but not on `export` | Policy code |
| 6 | Escalation through role assignment | A role that can assign roles can grant one more powerful than itself, or itself | Policy code + Rolify config |
| 7 | Hierarchy anomalies | A cycle in role inheritance, or a junior role that inherits a senior grant | Role config |
| 8 | Separation-of-duty violation | One user holds both `requester` and `approver`, or approves their own request | Role config + runtime |
| 9 | Stale access after revocation | Role removed, but a cached decision, session or token still allows the action | Runtime (temporal) |
| 10 | Unchecked actions | A controller action runs with no `authorize` call at all | Runtime |
| 11 | Policy stricter than the catalog | Admins may manage accounts but must never read card data; a leak to admins | User-declared restriction |
| 12 | Mass-assigned privilege | `params.permit(:role)` or `:admin` reachable by non-admins | Static (strong params) |
| 13 | Cross-tenant access | A role, ownership or invite from one org works on another org's records; six variants (M1 to M6) under Memberships | Runtime + policy code |
| 14 | GraphQL exposure gaps | A sensitive field, nested type, node lookup or mutation skips the check the REST path has; six variants (G1 to G6) under GraphQL | Schema walk + runtime tracing |
| 15 | Policy-DSL hazards | A weak prevent rule, an overrides that drops the parent's prevents, or a condition cached at the wrong scope; four variants (D1 to D4) under DeclarativePolicy | Policy code + runtime |

Rows 11 and 12 answer SPACE's two published weak spots: it cannot express policies stricter than its patterns (false negatives), and it maps whole resource types, so per-field rules showed up as its 10 false positives.

## Prior art

The core idea is proven and published; what is missing is a maintained, modern-Ruby tool, since the SPACE code is a preliminary research archive from 2016.

| Work | What it did | What Hallmark takes | What Hallmark changes |
| --- | --- | --- | --- |
| [SPACE](https://groups.csail.mit.edu/sdg/pubs/2016/access-control-patterns-icse2016.pdf) (Near, Jackson, ICSE 2016) | Checked every data exposure in a Rails app against 7 RBAC patterns in Alloy: ownership, public objects, authentication, explicit permission, user profiles, administrators, explicit roles. 30 apps with access control, 23 bugs, 10 false positives, every run under 64 s. | The pattern catalog, the user-supplied type mapping DSL, the "every exposure must match a pattern" check, small default bounds | Facts come from policy code and runtime events, not symbolic execution; field-level mapping; user-declared restrictions; temporal checks |
| [Rubicon](https://dspace.mit.edu/handle/1721.1/86919) (Near, Jackson, FSE 2012) | RSpec-style specs for Rails apps, checked by Alloy after symbolic execution | An RSpec-flavoured way to state custom properties | Properties run against extracted facts, not a symbolic Rails |
| Derailer (Near, Jackson, ASE 2014) | Interactive tool that listed how data is exposed so a developer could spot inconsistent checks | The exposure report as a human-readable artifact | Reports are generated, not explored interactively |
| RBAC in Alloy (Schaad and Moffett; BBN's AVDA RBAC schema debugger) | RBAC96 and ARBAC97 models with separation-of-duty conflicts in Alloy | Structural checks: hierarchy, SoD, assignment escalation | Driven from the app's real role config |

SPACE's evaluation also sets expectations for bounds: a scope of 3 was enough for every bug it found, and scope 8 still finished in under 10 seconds. Its own limits list is Hallmark's design brief: it assumes production behaves like analysis time, only sees ActiveRecord-to-view flows, and can miss bugs outside the bound.

## Embedding Alloy in Ruby

Use a gem-managed JVM sidecar by default and add an in-process JRuby backend second; both sit behind one `Hallmark::Solver` interface. Alloy 6.2.0 is the current release, Apache-2.0 licensed, and published to Maven Central as separate core, API, CLI and Pardinus (solver) artifacts, so it can be pinned like any dependency. Its documented Java entry points are `CompUtil.parseEverything_fromString` and `TranslateAlloyToKodkod.execute_command`.

| Option | How it works | Strengths | Weaknesses | Verdict |
| --- | --- | --- | --- | --- |
| A. JVM sidecar | Small Java shim (`hallmark-solver.jar`) wrapping the Alloy API; JSON-RPC over stdio; spawned and supervised by the gem | Works on any CRuby; solver memory and timeouts cannot take down Puma; warm JVM amortizes startup | Needs a JRE 17+ where analysis runs (a JDK to build it); serialization cost | **Built Oct 15, 2026**; opt-in in phase 1 (`c.solver = :sidecar`), the intended default |
| B. In-process on JRuby 10 | `require` the Maven jars and call the Java API directly | No IPC; direct access to AST and instances | JRuby 10 tracks Ruby 3.4 and needs Java 21; most Rails shops run CRuby | **Second backend** |
| C. Shell out to the 6.2 CLI | Write `.als`, run `alloy exec --type xml`, read verdicts from `receipt.json` and witnesses from the XML instances | Zero Java code | Cold JVM per run (about 1 s for three to six checks on an M4 Max); coarse control | **Phase 0 backend (built)**; the phase 1 default and the sidecar's cross-check |
| D. GraalVM native-image of the shim | Compile option A to a native binary | No JRE to install; fast start | Reflection config, native SAT solver libraries | **Later optimization** |
| E. Rjb or JNI inside CRuby | Load a JVM into the Ruby process | No sidecar | Unsafe with forking servers and preload; crashes take the app down | Rejected |
| F. Swap Alloy for SMT | Encode to Z3 or cvc5 instead | Unbounded proofs | Not Alloy; SPACE notes its quantifier alternation makes the check undecidable, which favours a bounded model finder | Out of scope |

Solver choices inside the shim: SAT4J (pure Java) as the default for portability, native MiniSat or Glucose from the dist jar as an opt-in for speed. Alloy 6 temporal checks run as bounded traces on the SAT backend; unbounded temporal checking needs NuSMV or nuXmv on the PATH, so v1 avoids it.

The shim protocol stays tiny: `load(model_text) -> model_id`, `check(model_id, command, scope, timeout_ms) -> {sat, instance}`, `eval(model_id, instance_id, expr)`. Instances come back as JSON atoms and tuples, which the Ruby side maps back to app classes and record ids. "The shipped sidecar" under "Runtime modes and performance budget" describes the protocol as built.

## Architecture

Two extractors feed one fact store; everything from the model builder down runs in CI or a background worker, never inside a request.

Requests only append events; all solving runs in a separate JVM. Only the runtime collectors sit on the request path.

```text
Ruby process (CRuby or JRuby)
  Static extractor                      Runtime collectors  (request path)
  Prism: policies, routes,              Action Policy, Pundit, DeclarativePolicy,
  role config, strong params            ActiveRecord hooks, graphql-ruby tracing
            \                                 /
             v                               v
  Fact store: events deduped into stamps, plus a role-config snapshot
             |
             v
  Model builder: mapping DSL + catalog + extracted guards = generated .als
             |
             v
  Solver client: JSON-RPC over stdio  ---- check ---->  JVM sidecar
  (a timeout is reported as unknown)                     Alloy 6.2 core: parse, type-check, translate
                                                         Pardinus + SAT solver: SAT4J default, MiniSat opt-in
  Witness decoder: atoms back to   <---- result ----
  app classes and records
             |
             v
  Reporters: RSpec, CLI, SARIF, alerts, verdict table
```

Static extraction gives coverage of code paths no request has hit yet; runtime collection confirms what the code actually decides. Disagreement between the two is itself a finding (drift). The sidecar is stateless apart from loaded models, so it can be restarted on a timeout or memory cap without losing anything.

## The Alloy model

The models below ran on Alloy 6.2.0 (`java -jar alloy.jar exec`) on Oct 14, 2026, and every check returned the intended verdict. The trick that makes runtime data useful to a solver: Hallmark does not feed it individual requests. It generalizes them into one predicate per controller action, the guard condition recovered from policy code and confirmed by observed allow and deny decisions, then asks Alloy whether that guard can ever allow something the catalog does not.

**1. The phase 0 catalog** (`catalog.als`), SPACE's patterns plus structural RBAC checks. Phase 1 made the shipped catalog tenant-aware; "Memberships and multiple tenants" shows what changed.

```alloy
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
pred owns[p: Principal, r: Resource]    { authenticated[p] and r.owner = p }
pred publicRead[o: Op, r: Resource]     { o = Read and r in Public }
pred isAdmin[p: Principal]              { Admin in effective[p] }
pred granted[p: Principal, o: Op, r: Resource] {
  authenticated[p]
  some g: Grant | g.role in effective[p] and g.op = o and r in g.res
}
pred allowed[p: Principal, o: Op, r: Resource] {
  owns[p, r] or publicRead[o, r] or isAdmin[p] or granted[p, o, r]
}

-- Structural checks over the app's real role config
assert NoHierarchyCycles { no r: Role | r in r.^inherits }

sig Conflict { a, b: one Role }                 -- separation-of-duty pairs
assert StaticSoD { no u: User, c: Conflict | c.a + c.b in effective[u] }

sig CanAssign { by: one Role, gives: one Role }  -- who may hand out which role
assert NoEscalationByAssignment {
  all u: User, c: CanAssign |
    c.by in effective[u] implies c.gives.*inherits in effective[u]
}
```

**2. A generated per-action check** (`blog.als`), the SPACE MediumClone bug in Hallmark's form:

```alloy
module blog
open catalog

sig Post extends Resource {}

-- Generated from PostsController#update (seen 1,204 times in shadow mode)
-- Guard recovered from PostPolicy#update?: user.present?
pred posts_update[p: Principal, r: Post] { authenticated[p] }

assert PostsUpdateIsSafe {
  all p: Principal, r: Post | posts_update[p, r] implies allowed[p, Write, r]
}
check PostsUpdateIsSafe for 5
```

**3. A temporal check** (`revocation.als`), using Alloy 6 mutable fields for threat 9:

```alloy
module revocation

sig Role {}
sig Resource { needs: one Role }
sig User { var roles: set Role, var cached: set Resource }

pred unchangedExcept[u: User] {
  all x: User - u | x.roles' = x.roles and x.cached' = x.cached
}
pred decide[u: User, d: Resource] {        -- an allow decision gets cached
  d.needs in u.roles
  u.cached' = u.cached + d
  u.roles' = u.roles
  unchangedExcept[u]
}
pred revoke[u: User, r: Role] {            -- the app's revocation path
  r in u.roles
  u.roles' = u.roles - r
  u.cached' = u.cached                     -- generated from code: cache not cleared
  unchangedExcept[u]
}
pred stutter { roles' = roles and cached' = cached }

fact traces {
  no cached
  always (stutter
          or (some u: User, d: Resource | decide[u, d])
          or (some u: User, r: Role | revoke[u, r]))
}

assert NoStaleAccess { always all u: User | u.cached.needs in u.roles }
check NoStaleAccess for 3 but 6 steps
```

What the solver returned ("counterexample" means a vulnerability with a concrete witness):

| Check | Result | Witness |
| --- | --- | --- |
| `PostsUpdateIsSafe` (guard: logged in) | Counterexample | `User$0` updates `Post$4`, which it does not own and holds no grant for |
| Same check, guard: `record.user == user` | Holds within scope 5 | None |
| `NoStaleAccess` | Counterexample | 3-step trace: `User$2` holds `Role$0`, caches `Resource$2`, loses the role, keeps access |
| `NoHierarchyCycles` on a sample Rolify config | Holds within scope 4 (6 roles) | None |
| `StaticSoD` on the same config | Counterexample | One user assigned both `Requester` and `Approver`; nothing forbids it |
| `NoEscalationByAssignment` | Counterexample | A `Support` user can assign `Editor`, a role they do not hold |

The CLI writes a `receipt.json` per run plus one XML instance per counterexample. Phase 0 found that the receipt's own `values` map keys atoms by their parent signature and silently drops some, so verdicts come from `receipt.json` and witnesses (skolems and field tuples) from the A4 XML. The sidecar should return witnesses in a shape the same decoder can read.

## Memberships and multiple tenants

When a user can belong to several tenants (organizations, groups, Gumroad sellers), a role is a fact about a (user, tenant) pair, so every check must answer "in which tenant?". Hallmark makes tenancy a dimension of the whole catalog rather than one more pattern; on Oct 14, 2026 the model below found all six cross-tenant flaws listed here and found no counterexample for the fixed guard within scope 4. The examples use an app whose tenant class is `Organization`.

What changes in the model:

- **Membership replaces global assignment.** `Membership(user, tenant, roles)`, at most one per user and tenant; a user's roles in tenant A say nothing about tenant B.
- **Every record has a tenant.** Ownership, grants and admin rights are evaluated inside the record's tenant, so creating a record no longer grants access after the creator leaves that tenant.
- **The request carries a current tenant** (subdomain, path segment, session, header, `Current.organization` or an authorization context entry). Guards are checked for every pairing of the current tenant and the record's tenant, which is where most real cross-tenant bugs live.
- **Rolify grants outside an instance are modeled explicitly.** A global role, or one scoped to the `Organization` class, satisfies the instance-scoped check for every tenant unless Rolify's strict mode or `has_strict_role?` is used.
- **Intended cross-tenant access is declared, not guessed.** Platform roles (the vendor's support or billing staff) are listed in the mapping so they are not reported.
- **A tenant may itself be a principal.** In Gumroad the tenant is the seller, a `User` row, and team members act for it through `TeamMembership`; `role_owner_for?(seller)` is just `seller == self`. The mapping's `self: :owner` option gives every such tenant an implicit owner membership in itself, and products map with `tenant: :user` and no owner.

| # | Flaw | Guard Hallmark extracted (example) | Witness Alloy returned |
| --- | --- | --- | --- |
| M1 | Unscoped role check | `current_user.memberships.exists?(role: :admin)` | An admin of one org destroys a project in another org |
| M2 | Current-tenant confusion | Admin of `Current.organization`; record loaded with `Project.find(params[:id])` | An admin of the current org edits a project belonging to a different org |
| M3 | Ownership outlives membership | `record.creator == user` | A user with no remaining membership still edits a project they created |
| M4 | Cross-org invitation | Admin of the current org; target org read from `params[:organization_id]` | An admin of one org creates an invite into an org where they hold no admin role |
| M5 | List scope spans all orgs | `policy_scope` returns projects from every org the user belongs to | While viewing org 2, the list includes org 1's projects (may be an intended dashboard, so Hallmark asks) |
| M6 | Rolify grant at the wrong scope | `has_role?(:admin, org)` with a global or class-level grant present | Admin rights in an org the user is not a member of |

The core of `research/models/tenancy.als`, with M2 and its fix. The research model calls the tenant `Org` and the current tenant `cur`; the port into the shipped catalog renames the sig to `Tenant`.

```alloy
sig Org {}
sig Membership { user: one User, org: one Org, roles: set Role }
fact OneMembershipPerUserAndOrg {
  all u: User, o: Org | lone m: Membership | m.user = u and m.org = o
}
abstract sig Resource { tenant: one Org, owner: lone User }

fun membershipIn[p: Principal, o: Org]: set Membership { user.p & org.o }
pred member[p: Principal, o: Org] { some membershipIn[p, o] }
fun rolesIn[p: Principal, o: Org]: set Role { membershipIn[p, o].roles.*inherits }

-- Tenant-aware catalog: every pattern is evaluated inside the record's org
pred owns[p: Principal, r: Resource]     { member[p, r.tenant] and r.owner = p }
pred orgAdmin[p: Principal, r: Resource] { OrgAdmin in rolesIn[p, r.tenant] }
pred granted[p: Principal, o: Op, r: Resource] {
  some g: Grant | g.role in rolesIn[p, r.tenant] and g.op = o and r in g.res
}
pred allowed[p: Principal, o: Op, r: Resource] {
  owns[p, r] or orgAdmin[p, r] or granted[p, o, r]
}

-- M2: admin of Current.organization, record loaded by id only
pred projects_update[p: Principal, cur: Org, r: Project] { OrgAdmin in rolesIn[p, cur] }
pred projects_update_fixed[p: Principal, cur: Org, r: Project] {
  OrgAdmin in rolesIn[p, cur] and r.tenant = cur
}
assert ProjectsUpdateIsSafe {
  all p: Principal, cur: Org, r: Project | projects_update[p, cur, r] implies allowed[p, Write, r]
}
check ProjectsUpdateIsSafe for 4            -- counterexample
check ProjectsUpdateIsSafe for 4 but 1 Org  -- no counterexample: the bug is invisible
```

**Scope rule:** the last line is the lesson. With one tenant in scope, the M2 bug cannot be represented and the check finds no counterexample. Hallmark therefore never lets tenants drop below 2. The tenant bound is the overall scope, which is never below 2; when tenants are users, `Principal` (Anonymous plus every user) also needs at least 3, so at scope 2 the model builder emits `for 2 but 3 Principal`. Forcing every instance to contain a user with memberships in two tenants is unnecessary: the bounded search already covers every instance that has one.

**The shipped encoding** (phase 1 step 1, done Oct 15, 2026) is the research model with `Org` renamed `Tenant`, plus what the Gumroad mapping needs:

- `sig Tenant { user: lone User }`: when tenants are users (`self: :owner`), facts make `user` a bijection onto the tenants, give each tenant's user the self role in a membership of its own tenant, and give that role to nobody else.
- `sig Membership { member: one User, within: one Tenant, roles: set Role }`, at most one per user and tenant.
- `abstract sig Resource { owner: lone User, tenant: lone Tenant, ownerOutside: set Op }`: a tenant-aware resource has exactly one tenant; any other has none. An analysis without a tenant gets `no Tenant and no Membership`, so its patterns are exactly SPACE's. A resource mapped with `tenant_optional: true` (added Oct 18, 2026, for Forem, whose articles belong to an organization or to none) has at most one (`lone r.tenant`); for a record with none the collectors count roles held outside tenants, as `rolesFor` does.
- `rolesFor[p, r]` is the principal's roles in the record's tenant, or its roles outside tenants (`assigned`) when the record has none. Ownership also requires membership in the record's tenant (M3); the administrator and explicit-permission patterns use `rolesFor`.
- Platform staff: `sig PlatformRole in Role`, pinned to the declared platform roles. Holders may do anything in any tenant. In a tenant-aware mapping, users hold only platform roles outside tenants, and the analysis rejects a guard that checks any other role there (it would pass vacuously).
- Guards in a tenant-aware model take `[p: Principal, cur: Tenant, r: <Sig>]`, so the witness carries the skolem `$<check>_cur`. Guard terms: `role(:x, tenant: :current | :record | :any)`, `in_current_tenant` (`r.tenant = cur`) and `outside_tenants` (`no r.tenant`, added Oct 18, 2026). The analysis rejects `outside_tenants` on a resource not mapped with `tenant_optional:`, where it is always true or always false.
- Explicit permission on one record (added Oct 16, 2026, for Gumroad's collaborators): `sig Permit { holder: one User, ops: set Op, target: one Resource }` and the pattern `permitted[p, o, r]`, outside any role or tenant. A resource mapped with `permits:` may carry permits; the model pins `no target.<Sig>` on every other resource, and `no Permit` when none has the option. The guard literal `permitted` renders as `permitted[p, <exposure op>, r]`, so `Guard#to_alloy` takes the op.
- Ownership without membership (added Oct 21, 2026, after the phase 2 gate; HCB's card grants go to people outside the organization's team): `ownsOutsideTenant[p, o, r]` lets a signed-in owner perform the ops in `r.ownerOutside` without a membership in the record's tenant. `resource ..., owner_outside_tenant: true` (or `:read`, `:write`, a list) sets them; it needs `owner:` and `tenant:`. The model pins `all r: <Sig> | r.ownerOutside = ...` or `no <Sig> <: ownerOutside` on each resource, and `no ownerOutside` when no resource has the option.
- Public actions (added Oct 21, 2026, for HCB's donation page): `publicAction[p, audience]`, with the audience `Principal` (everyone) or `User` (every signed-in user, SPACE's authentication pattern). Unlike the other patterns it belongs to an action, not to a kind of record, so it is not part of `allowed`: `public_action POLICY, RULE..., audience: :anyone | :signed_in, when: <flag guard>` declares it per rule, and a check whose rules all have one asserts `allows implies (allowed[p, op, r] or (publicAction[p, <audience>] and <when>))`. An exposure names its rules (`Exposure#rules`); an entry point enforcing several gets the narrowest audience and the AND of the conditions, and none if any rule has no public action (`Mapping#public_action_for`).
- Role facts (added Oct 16, 2026): `Role` is exactly `Admin` plus the declared roles and `no inherits` until `role_hierarchy` exists; platform roles are never held in a membership; the catalog's `Admin` is held by nobody unless some guard checks `admin`. Without these the solver returned witnesses holding undeclared roles that inherit a declared one, or `Admin` inside a seller.

M1, M2 and M3 are expressible today (`tenant: :any`, a role in `:current` without `in_current_tenant`, `owner`); `test/storefront_test.rb` checks each. M4 (invitations), M5 (list scopes) and M6 (Rolify grants outside an instance) need resources and mapping options not built yet.

**Mapping additions:**

```ruby
c.map do
  principal User
  tenant Organization, membership: Membership, member: :user, roles: :role  # or rolify: true
  current_tenant -> { Current.organization }   # or ActsAsTenant.current_tenant
  platform_role :support                        # cross-tenant access that is intended
  resource Project, tenant: :organization, owner: :creator
end

# Gumroad: the tenant is the seller, itself a User
c.map do
  principal User
  tenant User, membership: TeamMembership, member: :user, roles: :role, self: :owner
  current_tenant ->(ctx) { ctx.seller }
  platform_role :is_team_member                 # Gumroad staff (a bit flag)
  resource Link, tenant: :user                  # products; no personal owner
end
```

**New runtime facts per stamp**, all booleans or role names: which source set the current tenant, whether the record is in the current tenant, whether the user is a member of the record's tenant, and the user's role set in both tenants. The static extractor also flags role checks that take no tenant argument, and tenant-owned models that skip the app's tenant scoping (for example a model with an `organization_id` column but no `acts_as_tenant`).

**Where the current tenant comes from:** Action Policy can pass extra authorization context (such as the current account) into every policy, so its collector gets the current tenant for free; Gumroad's port declares `authorize :seller`. Pundit apps usually wrap user and tenant in a context object, which the mapping names (Gumroad's `context.seller`). Background jobs have no request, so the collector flags jobs that load tenant-owned records without a tenant argument.

## GraphQL field authorization (v1)

v1 treats a graphql-ruby schema as a second set of entry points: every root field, `node(id:)` lookup and mutation is an exposure, and every object reached through nested fields is held to the same catalog and membership rules as a controller action. On Oct 14, 2026 the model below found three schema-level bugs and found no counterexample for the fixed schema within scope 4.

**What graphql-ruby gives Hallmark to work with:**

- **Visibility:** `visible?` hides parts of the schema from a context; Hallmark treats hidden fields as unreachable for that viewer.
- **Scoping:** `self.scope_items(items, context)` runs by default only on list and connection fields; single-object fields are unscoped unless they set `scope: true`, and `reauthorize_scoped_objects(false)` skips per-object checks after scoping.
- **Authorization:** type-level `self.authorized?(object, context)`, field `#authorized?(obj, args, ctx)`, argument `#authorized?`, and `ready?` plus `authorized?` on mutations. `loads:` arguments fetch through `object_from_id` and run the loaded type's `authorized?`. Unauthorized objects become `nil` by default; the schema's `unauthorized_object` and `unauthorized_field` hooks override that.
- **Policy libraries:** Action Policy's GraphQL integration adds `authorize:`, `preauthorize:` and `authorized_scope:` field options; Pundit and CanCan integrations ship in GraphQL::Pro.

**How facts are collected:**

- **Static:** walk the schema's type and field graph by reflection (types, fields, arguments, `loads:`, Node implementations), then run the Prism extractor over `authorized?`, `scope_items` and resolver bodies. The result is a graph with an extracted guard on every type, field and argument.
- **Runtime:** a `trace_with` module records, per resolved field, the field path, parent and child types, the `authorized?` outcome, whether a value was replaced by `nil`, and the current org from `context`. Events are deduplicated by field path and decision, never stored per query.

| # | Flaw | What it looks like | Detected by |
| --- | --- | --- | --- |
| G1 | Field-level leak | `User.email` sits on a type many viewers can reach, with no field check | Alloy: anonymous viewer reads a user's email via `node(id:)` |
| G2 | Nested path bypass | `InvoiceType` has no `authorized?` because "only admins navigate there" | Alloy: a non-admin org member reads invoices via `organization { projects { invoices } }` |
| G3 | Node lookup bypass | A type implements Node but defines no `authorized?` | Alloy: anonymous viewer fetches any User by global ID |
| G4 | Mutation checked late or not at all | A custom `load_*` method skips type checks; Action Policy `authorize:` on a mutation (runs after execution); no `ready?` or `authorized?` | Static rule, plus runtime: a database write traced before the authorization event |
| G5 | Scope switched off | `scope: false` on a list, or `reauthorize_scoped_objects(false)` with a scope that ignores the tenant | Static rule; Alloy via the membership model (M5) |
| G6 | Context mismatch | `context[:current_organization]` differs from the controller's current org, or is missing in subscriptions and batch loaders | Runtime comparison; Alloy via M2 |

The core of `graphql.als`: a viewer's exposure is everything reachable from the entry points, where each step must pass the field's check on the parent and the child type's `authorized?`.

```alloy
abstract sig Guard {}
one sig NoCheck, LoggedIn, TenantMember, TenantAdmin, SelfOrAdmin extends Guard {}

abstract sig GType { guard: one Guard, policy: one Guard }  -- extracted vs intended
sig NodeType in GType {}                                     -- implements Relay Node
sig Obj { gtype: one GType, tenant: one Org, represents: lone User }
abstract sig GField { src: one GType, dst: one GType, guard: one Guard, link: Obj -> Obj }
abstract sig RootList { returns: one GType, scope: one Guard }  -- scope_items

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

pred objectsOk[t: GType] {
  all p: Principal, o: exposed[p] & gtype.t | passes[t.policy, p, o]
}
G2_NestedInvoices: check { schema and extractedGuards implies objectsOk[InvoiceT] } for 4
```

| Check (sample schema: Org, Project, Invoice, User) | Result |
| --- | --- |
| G2: invoices reachable only by org admins | Counterexample |
| G3: users readable only by signed-in viewers | Counterexample |
| G1: `User.email` readable only by that user or an org admin | Counterexample |
| Same schema with every extracted guard equal to its policy | Holds within scope 4 |

**Mapping additions.** Most types inherit their policy from the model they wrap (`Types::ProjectType` backs `Project`), so only exceptions are declared:

```ruby
c.graphql AppSchema do
  current_tenant ->(ctx) { ctx[:current_organization] }
  policy       Types::InvoiceType, :tenant_admin
  field_policy Types::UserType, :email, :self_or_admin
end
```

Reports name the query a client would send, for example: an anonymous `node(id:)` lookup on a User global ID returns `email`, because `UserType` defines no `authorized?` and `email` has no field check.

## DeclarativePolicy adapter (v1)

Hallmark v1 ships a third adapter for the `declarative_policy` gem (MIT licensed), the framework GitLab built and uses for its authorization. Its rules are already declarative, so translation is more exact than for Pundit or Action Policy: each `rule { ... }.enable` or `.prevent` line becomes one Alloy formula, and only condition bodies remain ordinary Ruby. On Oct 14, 2026 the model below found three DeclarativePolicy-specific flaws and found no counterexample for the fixed rule within scope 4.

| DSL | Alloy translation |
| --- | --- |
| `condition(:member) { @subject.member?(@user) }` | A predicate over (user, subject); the body goes through the Prism subset or the mapping, otherwise it stays opaque |
| `rule { a & ~b }.enable :x` and `.prevent :x` | One enabling or preventing formula for ability `x`; `&`, `\|`, `~`, `all?`, `any?` become and, or, not |
| Ability semantics | Allowed only if at least one enabling rule holds and no preventing rule holds |
| `can?(:y)` inside a rule | A reference to ability `y` on the same subject |
| `delegate { @subject.project }` | The delegate's enable and prevent rules, evaluated on the delegated subject |
| `overrides :x` | Drops the delegate's rules for `x`, both enable and prevent |
| `scope: :user`, `:subject`, `:global` | Recorded as the condition's cache key and checked against what its body reads |

**How facts are collected:**

- **Static:** Prism parses `rule` blocks, `delegate`, `overrides` and `condition` declarations. The rule DSL is a small, closed language, so this needs no gem internals. Ability names are app-specific, so the mapping assigns each one a catalog operation; unmapped abilities are listed in the report.
- **Runtime:** the gem documents no instrumentation hooks, so the collector prepends a module on `DeclarativePolicy::Base#allowed?` and records policy class, ability, decision and subject class. In `test` mode, `policy.debug(ability)` shows which rules fired, which Hallmark uses to explain drift.
- **Memberships:** GitLab-style inheritance, where a group membership flows down to subgroups and projects, maps onto the membership model with an `inherits_from:` option on the tenant.

| # | Flaw | Example | Detected by |
| --- | --- | --- | --- |
| D1 | Prevent rule too weak | `rule { confidential & ~member }.prevent :read_issue` | Alloy: a member who is neither author nor maintainer reads a confidential issue |
| D2 | `overrides` drops the parent's prevents | `overrides :read_project` plus `rule { author }.enable :read_project` | Alloy: a blocked author still passes `:read_project` on their issue; plain delegation holds |
| D3 | Condition cached at the wrong scope | `condition(:member, scope: :user)` whose body reads `@subject` | Static rule; Alloy: the first project's answer is reused, so a user reads a different private project |
| D4 | Boolean operators in a rule block | `rule { member && maintainer }` | Static rule: conditions are objects, not booleans, so `&&`, `\|\|` and ternaries do not combine them; GitLab bans these with a custom cop |

The core of `declarative.als`, with D1 and D2:

```alloy
-- ProjectPolicy
--   rule { public_project | member }.enable :read_project
--   rule { blocked }.prevent :read_project
pred read_project[u: User, p: Project] {
  (p in Public or member[u, p]) and not u in Blocked
}

-- IssuePolicy: delegate { @subject.project }
--   rule { can?(:read_project) }.enable :read_issue
--   rule { confidential & ~member }.prevent :read_issue           (as written)
--   rule { confidential & ~author & ~can?(:update_project) }...   (fixed)
pred read_issue_buggy[u: User, i: Issue] {
  read_project[u, i.project]
  and not (i in Confidential and not member[u, i.project])
}

-- Ability.allowed?(user, :read_project, issue)
pred issue_read_project[u: User, i: Issue] { read_project[u, i.project] }   -- delegated
pred issue_read_project_overridden[u: User, i: Issue] { i.author = u }        -- overrides

D1_ConfidentialPrevent: check {
  all u: User, i: Issue | read_issue_buggy[u, i] implies intended_read_issue[u, i]
} for 4
```

| Check | Result |
| --- | --- |
| D1: confidential issues readable only by author, maintainer | Counterexample |
| D1 with the fixed prevent rule | Holds within scope 4 |
| D2: `:read_project` on an issue through plain delegation | Holds within scope 4 |
| D2: the same ability with `overrides` | Counterexample |
| D3: `member` cached per user | Counterexample |

**Mapping additions:**

```ruby
c.declarative_policy do
  ability :read_project,   op: :read,  resource: Project
  ability :update_project, op: :write, resource: Project
  ability :read_issue,     op: :read,  resource: Issue
  tenant  Namespace, inherits_from: :parent     # group to subgroup to project
end
```

## Ruby API sketch

The only thing a developer must write is the mapping from app types to catalog types, as in SPACE; everything else is inferred, and anything Hallmark cannot infer becomes a named open question in the report rather than a silent assumption.

**Mapping and declared restrictions** (`config/hallmark.rb`):

```ruby
Hallmark.configure do |c|
  c.solver  = :sidecar            # or :cli (the phase 1 default); :jruby later
  c.sat_solver = "sat4j"          # or the native "minisat", "glucose"
  c.scope   = 5                   # SPACE found every bug at 3; 8 stayed under 10 s
  c.timeout = 10                  # seconds per check, like HALLMARK_TIMEOUT

  c.map do
    principal User, roles: ->(u) { u.roles.pluck(:name) }   # Rolify
    resource  Post,    owner: :author, public_if: :published?
    resource  Profile, owner: :user,   kind: :profile
    resource  Link,    tenant: :user, permits: ->(user, link) { user.collaborator_for?(link) }  # built
    role_hierarchy admin: %i[editor approver], editor: %i[author]
    conflicts [:requester, :approver]
  end

  # Threat 11: stricter than the catalog's admin pattern
  c.restrict "admins never read card data" do
    deny role: :admin, op: :read, resource: PaymentMethod, fields: %i[number cvc]
  end
end
```

The mapping accepts class constants or class names as strings (as the MediumClone example and the unit tests use); both normalize to the class name. Constants need the app loaded: the Railtie loads `config/hallmark.rb` after boot and the RSpec matchers load it at match time, but `bin/hallmark` runs outside the app, so a file it reads names classes in strings (a constant there stops with an error saying so; decided Oct 16, 2026).

An analysis starts from a copy of the configured mapping (`Mapping#dup` copies the collections the DSL adds to; the Structs, Guards and lambdas inside stay shared, since nothing changes them once built), so an analyze block's `map` adds declarations for that analysis only and never changes the global configuration or the mapping the collectors read. Two analyze blocks may each add the same resource. `Analysis.new` without a block still shares the mapping it is given, as `RuleCheck` does (decided Oct 17, 2026).

`resource ..., permits:` (built Oct 16, 2026) is the explicit-permission pattern on single records, such as Gumroad's collaborators: a lambda taking the user and the record, or a method name on the user that takes the record, returning true for every op, or `:read`, `:write` or a list. The sketched `permits: { user:, target:, op: }` form, for a separate share model, is not built; a lambda over the share covers it.

**Rules and ops.** An exposure is keyed by its entry point, op and resource (`docs/adr/0001-exposures-keyed-by-entry-point.md`), and its check name carries all three (`safe_LinksController_show_read_Link`; the resource was added Oct 16, 2026, so an entry point that reads two kinds of record gets two checks); the rules it calls supply its guard. A Pundit or Action Policy rule gets its op from `Hallmark::Ops` (rewritten Oct 21, 2026, after the phase 2 gate; until then only `index?`, `show?` and `edit?` read): the mapping's `rule ..., op:`, else a name that says the rule only shows a page, else the verbs of the routes that reach it (a rule only GET requests reach reads), else write ("The shipped op inference"). The mapping overrides that per rule, for example `rule LinkPolicy, :publish?, op: :write`, and `rule LinkPolicy, :update?, guard: ...` replaces the inferred guard (with `resource:` naming the record it checks, for a rule no stamp shows and whose policy name does not say; added with the matchers, Oct 16, 2026). DeclarativePolicy abilities have no naming convention, so each is mapped explicitly (the `c.declarative_policy` block sketched in the DeclarativePolicy section is, as built, `rule ProjectPolicy, :read_project, op: :read` in the map block). Built with the collectors, Oct 15, 2026.

**Collectors**, one adapter per authorization library:

- **Action Policy:** subscribe to its built-in `action_policy.authorize` notification to tell `authorize!` from queries; its payloads carry policy class, rule and result but not the policy instance, so the facts come from a prepended `apply_r` (built; see "The shipped collectors").
- **Pundit:** no instrumentation exists, so `prepend` a module on `Pundit::Authorization#authorize` and on `policy_scope` (built).
- **No library:** a controller `around_action` records which actions finished without any authorization call (threat 10; built).
- **Data side (not built):** ActiveRecord `find` and `update` notifications tie a request to the record type and to how the record was loaded (through the current tenant or not). Phase 1 reads ownership and the other record facts through the mapping at decision time instead (`record.owner == current_user`, recorded as a boolean, never the ids).
- **graphql-ruby:** a `trace_with` module records each resolved field path, its `authorized?` outcome and any value replaced by `nil` (details under GraphQL).
- **DeclarativePolicy:** no instrumentation exists, so `prepend` a module on `DeclarativePolicy::Base#allowed?` (details under DeclarativePolicy).

**Static extractor:** Prism parses policy methods and translates a supported subset into Alloy guards: `user.present?`, `user.has_role?(:x)`, `user.admin?`, `record.user == user`, `record.user_id == user.id`, `record.published?`, `&&`, `||`, `!`. Anything outside the subset becomes an opaque predicate, and runtime decisions must agree with the extracted guard; a disagreement is reported as drift. How an extracted guard with opaque leaves is checked is in `docs/adr/0003-extracted-guards-are-bounded.md`; the build order is under "Roadmap", "Phase 2 plan".

**Where results show up:**

```ruby
# RSpec (require "hallmark/rspec"; built, see "The shipped matchers")
RSpec.describe PostPolicy, :hallmark do
  it { is_expected.to satisfy_catalog }                 # every rule maps to a pattern
  it { is_expected.to have_no_counterexample(:update?) }
end
```

```bash
bin/hallmark check            # static + recorded stamps; exit 1 on any counterexample, else 2 on any unknown, else 0
bin/hallmark check --sarif    # SARIF for GitHub code scanning annotations
bin/hallmark explain PostsController#update   # the witness, in app terms
```

A counterexample is always printed in app vocabulary: "a signed-in User who is not the Post's author can call `PATCH /posts/:id` (PostPolicy#update? only checks `user.present?`)."

## Runtime modes and performance budget

The solver never runs inside a request: the request path only appends a small event, and verification cost scales with the number of distinct authorization shapes, not with traffic.

| Mode | Where | What runs | Fails what |
| --- | --- | --- | --- |
| `test` | Local and CI | Static extraction plus events from the test suite; every check, full scope | The build, on any counterexample or drift |
| `shadow` | Staging, or prod with a flag | Collectors on; sidecar checks new shapes in a background worker | Nothing; reports and alerts |
| `sampled` | Production | Collectors at a sample rate (default 1%); events shipped to a queue; checks run off-box | Nothing; alerts with the witness |
| `guard` (later, opt-in) | Production | No solving. Actions with an open counterexample are denied or logged from a verdict table built in CI | The request, if configured |

Budget and mechanics (targets set before phase 3; "The shipped hot path" below has the first measurements):

- **Hot path:** one struct appended to a per-thread ring buffer, aiming for under 20 µs p99 and zero allocations beyond the event; a flusher thread writes JSONL or a Redis stream.
- **Deduplication:** events collapse to a stamp: entry point, rule, decision, the principal's roles in the record's tenant and in the current tenant, and the mapped facts as booleans (owner? public? granted? member of the record's tenant? record in the current tenant?). A rule that raises is stamped as a deny. Only a new stamp, a new deploy or a changed role config triggers a re-check. In phase 1 stamps come from the test suite only, written as one deduplicated JSONL file per run under the app's `tmp/hallmark/`, never committed and rebuilt by CI.
- **Guards from stamps** (`docs/adr/0002-findings-from-observed-allows.md`): until the phase 2 extractor exists, a rule's guard is inferred as the OR of its allow-stamps, and a hand-written guard in the mapping overrides it. Findings come only from that lower bound; fact combinations that no stamp allowed or denied are reported as "not observed" coverage, never as findings.
- **Solver limits:** sidecar heap capped (default 512 MB), per-check timeout, one solver thread per core. A timeout is reported as "unknown", never as "safe".
- **Privacy:** events hold class names, rule names, role names, exception class names and booleans, and no ids at all, so phase 1 needs no HMAC. If the shadow and sampled modes (phase 3) need witnesses an operator can trace back to records, ids get HMAC-hashed with a per-environment key then. Decided Oct 21, 2026 that they do, opt-in: the hashed ids ride beside a stamp as its first-seen example and never join its key (`docs/adr/0004`).

**The shipped collectors** (phase 1 step 2, done Oct 15, 2026):

- **Stamps.** `Hallmark::Stamp` has the fields above plus `enforced` (an `authorize` call, as opposed to a query such as `allowed_to?`), `class_level` (the rule was checked against a class, a Symbol or nil in place of a record, so record facts are nil and `resource` names the class or the Symbol) and `raised` (the exception class). Collectors build one per decision on the request thread; `StampStore` pushes it onto a queue, and a flusher thread dedupes and appends new stamps to `tmp/hallmark/stamps-<run>-<pid>.jsonl`, with a `.gitignore` in the directory. Forked test workers share the run id and write one file each; `StampSet.load(dir)` reads every file of the latest run. Since Oct 17, 2026 the latest run is the one whose newest file has the newest mtime, ties broken by run id; before, it was the greatest run id as a string, so a word such as `HALLMARK_RUN=ci` outranked every later timestamp run and `"9"` outranked `"10"`. Limit: two suites writing into one directory at the same time cannot be ordered; name the run explicitly (`StampSet.load(dir, run:)`, or `let(:hallmark_stamps)` in RSpec). Threat 10 events (`unchecked`) go in the same file.
- **Facts are read through the mapping**, not through ActiveRecord hooks: `principal ..., from:` (default `:user`, the reader all three libraries give policies) finds the user, `principal ..., roles:` the roles outside tenants, `tenant ..., roles_in:` a user's roles in one tenant (the `self:` role is added on its own), `current_tenant` a policy reader, an Action Policy context entry or a lambda, and `resource` options (`owner:`, `public_if:`, `tenant:`) the record facts. A reader that is missing, or a user that is not the principal class, drops the stamp with one warning; a collector never breaks a request.
- **Action Policy:** the notifications carry only class and rule names, not the policy instance, so the collector prepends `apply_r` on `ActionPolicy::Base` (above its per-policy rule cache, so a cached `authorize!` after an `allowed_to?` is still seen) and on `Policy::Core` (policies that include only the core). It subscribes to `action_policy.authorize` with start and finish callbacks to mark an application as enforcing; that event exists when Action Policy's Rails instrumentation is on, the default. `authorized_scope` and `skip_verify_authorized!` count as checks.
- **Pundit:** prepends `authorize`, `policy_scope` and `skip_authorization` on `Pundit::Authorization`, passing the caller's arguments to Pundit untouched (apps compare `NotAuthorizedError#query` with a String or a Symbol). Rules called on the policy itself are stamped as queries (since Oct 18, 2026): they feed rule guards and tie no rule to an entry point. That covers policy specs that build the policy and call the rule (`described_class.new(user, record).public_send(:update?)`, as Forem's do), pundit/rspec's `permit` and pundit-matchers' `permit_actions`, and views calling `policy(record).edit?`; before, only `permit` was stamped, through a prepend on `Pundit::RSpec::Matchers` that this replaces, and Forem's 394 lines of policy-spec role cases left no stamp. Pundit policies share no base class (Forem's `LiquidTagPolicy` does not inherit `ApplicationPolicy`), so each policy class has each public method ending in `?` (minus `Object`'s) that it defines, or takes from an included module, replaced by a wrapper that calls the original (`UnboundMethod#bind`, so the original's `super` still reaches the parent class), passes the arguments, keywords, block and result through, and stamps through `Collectors.observe` (an exception is a deny, re-raised); rules from a parent class are wrapped on that class. The wrappers were first a prepended module per class; on Forem (Oct 18, 2026) that broke `allow_any_instance_of(ArticlePolicy).to receive(...)`, because RSpec refuses to stub a method a prepended module defines, so they moved onto the class itself, where RSpec's stubs replace and restore them as they would the app's own method. A policy class is one named `*Policy` whose `initialize` accepts `(user, record)` and that is not an Action Policy or DeclarativePolicy class; the arity test leaves out Rails' `ActionDispatch::ContentSecurityPolicy` and `PermissionsPolicy`. The wrappers go on at install for the classes loaded by then (`ObjectSpace`; Rails eager loads before `after_initialize`, so with `CI=true` that is every policy), and from then on a `TracePoint(:end)` wraps each class body Ruby finishes, which covers Zeitwerk autoloading, reopened classes and subclasses that override a rule, with no Rails dependency. Rejected: `Class#inherited`, which misses policies that inherit from `Object`; Zeitwerk's `on_load`, which misses classes loaded by `require` and needs Rails; and a scan at `before(:suite)`, which misses policies first loaded during an example and ties the hook to RSpec. A fiber-local flag marks a rule as running, and `authorize` sets it around Pundit's call, so a rule called inside `authorize`, a rule another rule calls (`edit?` calling `update?`) and a subclass rule's `super` are not stamped again: one stamp per outermost call. The record is the policy's `@record`, as Pundit's generator writes it; a policy that keeps it elsewhere is stamped class-level. Known limits: any public `?` method on a policy counts as a rule, so a public helper called directly is stamped under its own name (a rule with no op); the wrapper changes the rule's `arity` and `source_location` (its `owner` stays the policy class); and a rule added later with `define_method` outside a class body is not wrapped. A policy whose constructor raises (Gumroad's for anonymous users) yields no stamp, only a check. Any object including `Pundit::Authorization` may call `authorize` (a service object, a resolver run in a spec): outside a request the stamp has no entry point and stays enforced, as with Action Policy and DeclarativePolicy, so the rule feeds its guard and is listed as reached by no entry point. The hook reads nothing off its host beyond `action_name` when it has one, and stamping never raises into the caller or replaces the app's exception (fixed Oct 16, 2026; it used to name the entry point after the host and raised NoMethodError on a host without `action_name`).
- **DeclarativePolicy:** prepends `allowed?` on `DeclarativePolicy::Base`. The library has no enforcing call, so every decision counts as enforced, including a view's check that only renders a link; that can narrow an entry point's guard (missed findings, never false ones). Abilities have no naming convention, so each needs `rule POLICY, ABILITY, op:`; unmapped ones are listed in the report.
- **Threat 10:** an `around_action` on `ActionController::Base` and `API` names the entry point for decisions inside it and stamps `unchecked` when the action finished with no rule called, unless a filter halted the chain (detected through `halted_callback_hook`), the status is 400 or above, or it raised. The report fails on unchecked entry points, except those the mapping lists with `allow_unchecked`. Since Oct 17, 2026 the event also records the response status and the HTTP verb, and Inference excuses an unchecked request when all three hold: the verb is GET or HEAD, the status is a redirect (301, 302, 303, 307 or 308), and some other request to the same entry point left a stamp (allowed or denied) in the run. That covers an action body that redirects before authorizing (`return redirect_to root_path unless feature_enabled?` before `authorize @link`), which used to fail whenever a spec covered the branch, while `allow_unchecked` would have hidden the action's real unchecked paths. Each condition has a reason: a write that redirects has already acted, so a PATCH, POST, PUT or DELETE still fails; a 304 or an empty 2xx is not a redirect and still fails (the first may answer from data the request never authorized); and an entry point that only ever redirects without reaching a rule still fails, since a signed-URL or lookup redirect can hand out another user's record (an IDOR). Excused entry points are listed under coverage; an entry point with any request that is not excused fails and is not listed there. Lines written before the change have no status or verb and fail as before. Known limit: an entry point checked only through `policy_scope`, `authorized_scope` or `skip_authorization` leaves no stamp, so its GET redirects still fail; that is the conservative choice, and `allow_unchecked` remains the way out. The hook is a `prepend_around_action` (since Oct 19, 2026): the Railtie installs it after Rails eager loads the app, and a callback added to `ActionController::Base` then lands at the end of every existing controller's chain, after the controller's own filters, so an `authorize` in a `before_action` (Gumroad's `Bundles::BaseController#authorize_bundle`) ran outside the entry point, stamped with none, and the action was flagged as unchecked. The Gumroad port's differential run found it (Gumroad's specs run with `CI=true`, which eager loads). The GitLab and Forem gate runs, rerun with the fix the same day, gave identical stamps and reports: neither eager loads in tests, so their controllers loaded after the hook was installed and inherited it ahead of their own filters. Known limit: a filter the app itself prepends (`protect_from_forgery prepend: true`, GitLab's `prepend_around_action :set_current_context`) still runs before the hook, so an `authorize` there would stamp with no entry point.
- **Inference** (`Hallmark::Inference`): a rule's stamps on a mapped resource form a unit with an op (`Ops`: `rule ..., op:`, else the read names, else the routes' verbs, else other `?` rules write; "The shipped op inference"). Its inferred guard is the OR of its allow-stamps, each the conjunction of the facts that were true: `logged_in`, `public_record`, `owner`, `in_current_tenant`, `outside_tenants` (a `tenant_optional:` record with no tenant; added Oct 18, 2026), `role(:x, tenant: :current)`, `role(:x, tenant: :record)` (outside the current tenant only, since inside it the two coincide) and platform roles. False facts are dropped because every catalog pattern is monotone in them (more roles, ownership or membership never removes access), so dropping them changes no verdict; membership is implied by a role literal. Ownership is not monotone in the record's tenant, though: an owner keeps access to a record in a tenant only as a member (M3). So a record with no tenant gets the literal `outside_tenants`; without it an owner's allow there inferred a bare `owner`, which the model applies to records in a tenant too, and the counterexample persisted after the app was fixed. The stamp field `outside_tenants` is true for such a record and false for a record of the same resource in a tenant. Stamps written before Oct 18, 2026 leave it nil, and Inference reads a `tenant_optional:` record with no `record_roles` as outside tenants. Coverage splits on `outside_tenants` before `in_current_tenant`; when it is true, `in_current_tenant` and `record_roles` do not apply. The guard is printed with the literals all allow-stamps share factored out, in sorted order. An entry point's exposure ANDs the guards of the rules it enforced on one resource with one op; queries feed rule guards only.
- **Coverage** (`Hallmark::Coverage`): per rule, the fact space is split one fact at a time (logged in, public, owner, in the current tenant, then the role set held in the record's tenant, the current tenant and outside tenants), stopping where no stamp is left; each such region is one not-observed line. Role sets range over none, each single role and the sets some stamp shows. Also listed: rules with no observed allow, rules no entry point enforced, class-level rules, rules with no op, unmapped resources, and (since Oct 17, 2026) entry points whose GET redirects were excused from threat 10 because other requests to them reached a rule.
- **Railtie:** in `after_initialize`, when `HALLMARK_MODE` (or a `c.mode` set before boot) is `test`, or unset in the test environment, loads `config/hallmark.rb` and installs the collectors unless the file set `c.mode = "off"`. Loading after boot lets the mapping name app classes by constant: Rails sets up autoloading in its Finisher, after `load_config_initializers`, where the Railtie first ran (changed Oct 16, 2026). With the collectors off the file is not loaded, so development and console boots never autoload the mapped classes, and `c.mode = "test"` inside the file cannot turn them on. `hallmark check config/hallmark.rb` builds an analysis from the recorded stamps when the file declares only a mapping.
- **Known limits (collectors):** an entry point's guard comes from its rules alone, so an entry point that loads the record through the current tenant (`current_seller.links.find`) still inherits any cross-tenant allow its rule showed elsewhere, such as in a policy spec; the data-side collector that would record how the record was loaded is not built. An entry point that enforces rules of one op on two resources is rejected, as for hand-written exposures. A Symbol subject is stamped class-level and not modeled, like a class: a DeclarativePolicy global ability (subject `:global`), a headless Pundit policy (`authorize :dashboard, :show?`, or the last element of `[:admin, :dashboard]`) and a headless Action Policy one (`authorize! :dashboard, to: :show?`); the report lists them under "Rules checked against a class or a name". A String is still treated as a record, since no library uses one as a name (fixed Oct 17, 2026; before, a Symbol was read as a record, stamped `resource: "Symbol"` and listed as an unmapped resource).

**The shipped sidecar** (phase 1 step 3, done Oct 15, 2026):

- **Build.** `solver/src/hallmark/solver/` holds two Java files (`Sidecar`, and `Json`, a small parser so the shim depends on nothing but Alloy). `hallmark install-sidecar` (or `rake sidecar:install`) compiles them with the JDK's `javac --release 17` and `jar` against the pinned Alloy dist jar, which already carries every Alloy class and the native SAT solvers, so the build downloads nothing beyond `install-alloy`. The jar lands in `~/.cache/hallmark/hallmark-solver-<digest>.jar`, named by a SHA-256 of the sources, so a changed shim is rebuilt rather than run stale. The gem ships `solver/**/*.java`, never a jar.
- **Protocol** (version 1): JSON-RPC 2.0, one request per line on stdin, answers in order on stdout; anything Alloy prints goes to stderr. `version() -> {protocol, alloy, solver, solvers}`; `load(source, modules) -> {model_id, commands}`, where `modules` maps a module name to its text (the catalog), written next to the model in a scratch directory so `open catalog` resolves as it does for the CLI; `check(model_id, command, scope?, timeout_ms?) -> {verdict, ms, instance_id?, instance?, reason?}` with verdict `sat`, `unsat` or `unknown` and `scope` overriding the command's overall scope; `eval(model_id, instance_id, expr) -> {tuples} | {value}`; `unload(model_id)`. An instance is `{fields, skolems}`, tuples of atom labels keyed by relation label, the same shape `Receipt::Instance` builds from the A4 XML, so `Finding` reads both backends alike. Alloy errors come back as JSON-RPC errors (code 1) and the client raises `SolverError`.
- **Same answers as the CLI.** The shim calls `TranslateAlloyToKodkod.execute_commandFromBook` with default `A4Options` and the solver from `SATFactory.find`, as `alloy exec` does. On MediumClone and Storefront the two backends return the same verdicts and the same witnesses; `test/sidecar_integration_test.rb` asserts the verdicts and that every witness decodes.
- **Supervision** (`Hallmark::Solver::Sidecar`, with `Solver::ChildProcess` for the pipes): started on the first check with `-Xmx<c.sidecar_heap>m -XX:+UseSerialGC`, shared by every analysis in the process (`Hallmark.solver`), stopped by closing stdin. Each check carries `timeout_ms`; Alloy cannot interrupt a running solver, so on a timeout or `OutOfMemoryError` the shim answers `unknown` and exits (status 75), and the client restarts it and reloads the model for the next check. If no answer comes within `c.timeout` plus 5 s, the client kills the process; a crash mid-check is also unknown, with the exit status and the last lines of stderr as the reason. The first start failing, a protocol mismatch at that start, or an Alloy error raises instead, since no verdict could be right. Mid-run failures keep the verdicts already computed (changed Oct 17, 2026; before, they escaped `check` and lost them): a restart that fails (including a protocol mismatch after the jar was replaced, or a sidecar an earlier analysis left stopped) makes the rest of the run unknown with the start error as the reason, and so does loading the model when it times out or crashes, since the same model on the same heap would fail again. Unloading is best-effort: a failure there stops the sidecar and keeps every verdict.
- **Unknown everywhere.** `Receipt::Command#reason` marks a check with no verdict; `Report#unknown` lists them (`??` lines) and they are never counted as "no counterexample". `hallmark check` exits 1 on any counterexample or unchecked entry point, else 2 on any unknown, else 0. The CLI backend now reports a run that outlives `c.timeout` as every check unknown instead of raising.
- **Settings.** `c.solver`/`HALLMARK_SOLVER` picks the backend (`cli` by default, or `sidecar`); the SAT solver moved to `c.sat_solver`/`HALLMARK_SAT_SOLVER` (`sat4j`, `minisat`, `glucose`), and a SAT solver name in `HALLMARK_SOLVER` gets an error pointing there. `HALLMARK_SIDECAR_JAR` and `HALLMARK_SIDECAR_HEAP` (MB) override the jar and the heap cap. The CLI stays the default for now because one `hallmark check` process gains little from a warm JVM (it pays one JVM start either way) and the sidecar needs a JDK to build; the RSpec matchers (step 4), which run many small checks in one process, are where it pays off.
- **Measured** Oct 15, 2026 on an Apple M4 Max (Temurin 27, SAT4J, scope 5), Storefront's three checks: the CLI takes 0.93 s per run (about 310 ms per check, nearly all JVM start); the sidecar's first run takes 0.83 s (JVM start, class loading and JIT warm-up); warm, a whole run takes 105 ms, about 35 ms per check including the model load, of which the JVM reports 28 to 30 ms solving. The gate's 10 s per check is far off either way.
- **Not built:** concurrent checks (one solver thread per process; several sidecars could run checks in parallel), the native-image build (option D), and the JRuby backend (option B).

**The shipped matchers** (phase 1 step 4, done Oct 16, 2026):

- **Rules, not entry points.** `require "hallmark/rspec"` adds `satisfy_catalog` and `have_no_counterexample(:rule?)`. Both run on `Hallmark::RuleCheck`, which turns each rule of a policy into an exposure of its own, keyed by the rule and its resource (`LinkPolicy#update?` on Link; a rule stamped on two resources is two checks), and checks them in one solver run per matcher. Exposures stay keyed by entry point for `hallmark check` (`docs/adr/0001`); a rule check reads the rule's guard alone, so a rule that allows across tenants fails here even when every entry point loads the record through the current tenant, which is the point of checking the rule.
- **Verdicts.** A matcher passes only on "no counterexample within scope N". A counterexample fails it with the lines `hallmark check` prints (`Report.finding_lines`). An unknown fails it with its own message (raise `HALLMARK_TIMEOUT` or lower the scope). A rule with no allow-stamp and no hand-written guard fails it as "not observed": a coverage gap, never a finding (`docs/adr/0002`), but a pass would claim a check that never ran. `not_to` passes only on a counterexample (and, since phase 2 step 2, no drift; "The shipped drift"). `satisfy_catalog` covers the rules the stamps show plus those with a hand-written guard, and fails when there are none; a rule no test called is unknown to it until the phase 2 extractor reads policy code.
- **Mapping and guards.** The mapping is `let(:hallmark_mapping)` in the example group, else the configured one (the Railtie loads `config/hallmark.rb`), else `config/hallmark.rb` under the working directory. A rule's guard is the hand-written one, else inferred from stamps: `let(:hallmark_stamps)`, else the run the collectors are recording in this process (flushed first), else the latest run in `c.stamps` (the run written last, as "The shipped collectors" defines it). A hand-written guard on a rule no stamp shows checks the resource named by the policy (`LinkPolicy` checks `Link`) or by the new `rule ..., resource:` option.
- **Ordering.** Inferred guards need the stamps of the specs that exercise the policy, so the `:hallmark` tag runs tagged groups after their siblings, in random or defined order. RSpec's public `register_ordering` ignores changes once `--order` comes from the command line, so `Hallmark::RSpec.order_last` wraps the global strategy in RSpec's ordering registry, which RSpec marks private; without it the order is left alone. The tag also makes the policy class (or the string naming it) the subject, in nested groups too, since Pundit and Action Policy cannot build a policy without a user. With parallel workers, each process sees only the stamps written so far; share one `HALLMARK_RUN` and run the tagged specs after the workers finish.
- **Solver.** Inside RSpec the matchers share one backend: the sidecar, started on the first check and closed in `after(:suite)`, unless `HALLMARK_SOLVER` or `c.solver` chose one (`Configuration#solver_chosen?`); the CLI when the sidecar jar is missing. Storefront's spec (five examples, seven checks) takes about 1.7 s on the sidecar, mostly the JVM start, and 4.3 s on the CLI (Apple M4 Max, Oct 16, 2026).
- **Dependencies.** RSpec is a development dependency only; the matchers are plain objects with RSpec's matcher protocol, and `hallmark/rspec` configures RSpec only when it is loaded. Their tests run without Java on `FixtureSolver` and run RSpec itself in a child process.

**The shipped extractor** (phase 2 step 1, done Oct 19, 2026):

- **Reading.** `Hallmark::Extractor` parses `app/policies/**/*.rb` under the app root with Prism and never loads it (`SourceIndex`: classes and modules reopened across files merged, their `def`s and visibility, superclass and included modules resolved the way Ruby resolves constants, `alias_rule`, `alias_method`, `default_rule`, `pre_check`, `skip_pre_check`, and Rails class attributes set to a literal in a class body, directly or through a class method such as Gumroad's `allow_anonymous_user_access!`). The root is `c.root`/`HALLMARK_ROOT`: the Rails root under the Railtie, the parent of `config/` (else the file's directory) for the CLI, `let(:hallmark_root)` in a matcher's group. `HALLMARK_EXTRACT=off` turns it off. Its rules are each policy class's public `?` methods with no required arguments, plus aliases; a rule's resource is `rule ..., resource:`, else the policy's name without `Policy`, dropping leading namespaces until a mapped resource matches (`Admin::LinkPolicy` checks `Link`).
- **Translating** (`MethodTranslator`): `&&`, `||`, `!` and their keyword forms, `if`/`unless`/`elsif`/ternary, early exits (`return`, `raise`, `allow!`, `deny!`) splitting the rest of the body, the last expression as the value, literals, calls to the policy's own methods read in place with positional arguments and blocks bound (`when_record_available { ... }`), `allowed_to?(:rule?)`, `super`, locals read as what they were assigned, recursion as opaque. A constructor's exits and Action Policy's pre-checks wrap the rule, so Gumroad's `raise ... unless user` in `initialize` and the port's `pre_check :require_user` both read as `logged_in`. An Action Policy rule a policy does not define falls back to its default rule, else the base class's denial (pre-checks still apply). A Pundit policy answers no undefined rule.
- **Terms** (`Terms`): what an expression means, keyed by its normalized source (spacing, lone parentheses, `self.` and the `@` of instance variables dropped; comparisons either way round). Seeded per resource from the mapping (`owner:`, `public_if:`, `tenant:` with a Symbol `current_tenant`, `permits:` given as a method name) and globally (the principal reader, platform roles as methods on the user, `record.is_a?(Class)` false), then extended by `term "source", guard` in the map block, which wins. Lambda options cannot seed terms, so Gumroad's mapping adds `term` lines for `role_<x>_for?(seller)` and `collaborator_for?(record)`.
- **Bounds and checking** (`docs/adr/0003`): `Guard` gained `never` (rendered `(not unguarded)`) and `opaque` (never rendered; `to_alloy` raises). `Guard#bounds` folds constants. Inference gives a rule the lower bound OR its inferred guard (`basis` names both, with the rule's file and line), makes units for rules no stamp shows (listed under coverage as read from code with no entry point known), lists each opaque call under coverage, and drops the not-observed regions of a rule read exactly. `RuleCheck` and the matchers take the extractor too; a rule whose lower bound is `never` is not observed, with a reason naming the unread calls.
- **CLI.** `hallmark extract FILE` prints each rule's guard, or both bounds and the unread calls.
- **Gumroad, step 1's exit.** The same probe-free stamps as the Action Policy gate run (run 3's differential pair, byte-identical once sorted), with extraction: 14 checks, 2 counterexamples on both checkouts, the gate's real bug (`LinkPolicy#show?`, current-tenant confusion) and the data-side false positive the probe used to show, about 2.3 s per run; with extraction off, none, as before. With a rule-level fix applied to a copy of `app/policies` (`show?` also checking the seller), no counterexample, so both go: the detect-then-fix pair. The two reports differ only in the text of three opaque calls in a policy the port rewrote. A controller-level fix would need step 3 to show.
- **Known limits.** Entry points still come only from stamps (step 3), so a rule read from code that no test reached is checked by the matchers and listed by `hallmark check`, not checked there, and an entry point that loads its record through the current tenant still gets the rule's cross-tenant allows. `bin/hallmark check` ignored `HALLMARK_RUN` when reading and took the newest run (found on this run; fixed in step 2, "The shipped drift"). Modules included by policies are indexed only when they live under `app/policies`.

**The shipped drift** (phase 2 step 2, done Oct 19, 2026):

- **One reading of a stamp.** `Hallmark::StampFacts` (one stamp on one mapped resource) is the only code that says what a stamp's facts mean in catalog terms. `#literals`, moved out of `Inference`, gives the true facts an allow-stamp adds to the inferred guard, unchanged. `#[]` answers one guard leaf with true, false or nil (unknown): the mapping decides where the model's facts do (no owner, never public, always public, no tenant, no `permits:`: all fixed), an anonymous visitor holds no role, a record outside tenants gives no record roles, the current tenant's roles fall back to the record tenant's when the record is in it, and the rest comes from the stamp. Unknown: an opaque leaf, the catalog's `admin` (stamps record role names, not the catalog's Admin), `role(..., tenant: :any)` unless a stamped tenant holds it, and any fact a stamp left nil (roles in the current tenant when none was stamped, `permitted` in old lines). A test checks that every literal evaluates true on its own stamp.
- **`Guard#evaluate(facts)`**, three-valued in Kleene's sense: `and` is false when either side is, `or` true when either side is, anything else touching an unknown is unknown. `facts` is a `StampFacts` or a Hash from leaf to boolean (missing leaves unknown).
- **Drift** (`Hallmark::Drift`, from `Inference#drift`): an allow-stamp where the extracted guard's upper bound evaluates false, or a deny-stamp (a rule that raised included) where its lower bound evaluates true. An unknown is never drift, so a fact the collectors did not record cannot fail a build. Only units whose extracted rule is checked on the unit's resource count (terms are seeded per resource), and a rule with a hand-written guard has no drift, since that guard replaces the extracted one: it is the escape hatch for a rule whose term cannot be fixed. Stamps with the same rule, decision, bound and facts collapse into one drift listing their entry points ("outside a request" for none) and exceptions.
- **Report.** A "Drift" section after the per-check lines: `DRIFT <rule> (<resource>) at <file:line>: allowed, but its code allows only where <upper> (upper bound), false here` (or `denied (raised X), but its code allows wherever <lower> (lower bound), true here`), then the stamp's facts in coverage's notation and where it was stamped. Drift makes `Report#failed?` true, so `hallmark check` exits 1 through `Report.exit_code`, and the summary counts drifting decisions.
- **Matchers** (added Oct 19, 2026). `RuleCheck` attaches each unit's drift to its result (`Result#drift`, the rule on one resource), whatever the verdict, and `Result#lines` prints it under the verdict with `Report.drift_lines`, so the wording is the CLI's. A matcher fails on drift in the rules it checks, as the build does: `have_no_counterexample(:edit?)` fails on `edit?`'s drift and ignores `update?`'s, `satisfy_catalog` fails on any. `not_to` fails on drift too, even with a counterexample, since the guard that produced it is suspect. The message counts drifting decisions after the verdicts and ends with a note on fixing the `term` or writing the guard.
- **`HALLMARK_RUN` when reading.** `c.run` (from `HALLMARK_RUN`, nil by default) names the run `Analysis#add_stamps` reads from a stamp directory, so `hallmark check` and an analysis's `stamps` read the run the variable names, and the matchers' fallback to the latest run does too; nil keeps the newest run. A run with no files fails with the run's name in the message. Collectors still name the run they write from the same variable.
- **Gumroad.** Step 1's inputs (`stamps-pundit4` and `stamps-ap2`, read with `HALLMARK_RUN` and a stamp directory): no drift on either checkout, reports otherwise identical to step 1's. Of 159 stamps, the 38 on rules read from code with a mapped resource all get a definite value from both bounds and agree with their decisions, the same on both checkouts. Without `HALLMARK_RUN` the CLI reads the newest run (with the probe spec), so the variable now matters. Mapping `role_admin_for?(seller)` wrongly as the owner role alone gives 4 drifting decisions (seller admins' allows on four rules) and exit 1. Outputs in the private findings folder.

**The shipped controllers** (phase 2 step 3, done Oct 19, 2026; Grape moved to step 4):

- **Reading** (`Extractor::Controllers`, on a `SourceIndex` of `app/controllers`, which now also records Rails callbacks with their `only:` and `except:`, and the constants a class body assigns, so `except: PUBLIC_ACTIONS` resolves). For an entry point `Controller#action`: the `before_action` callbacks that run for the action, in order (`prepend_before_action` first, `skip_before_action` removes, a redeclared callback moves), then the action, plus the controller's own argument-less helpers they call, four levels down.
- **Record loading.** For every `authorize` or `authorize!` call there with a record (the first positional argument, the last element of Pundit's `[:ns, record]`; never a class or a Symbol), the record is followed back to how it was loaded: locals to their assignments in the method, instance variables to their assignments in the methods that run, helpers to their last statement (`@x ||= ...` reads as what it assigns), `x || e404` as `x`, and a call chain to its root. A root that is the controllers' current tenant reader (the new `current_tenant :seller, controller: :current_seller`) is scoped, and so is a model-class chain filtered by the resource's tenant (`Link.fetch(id, user: current_seller)`, `user_id: current_seller.id`, for `tenant: :user`); any other model class is unscoped; anything else is unknown. An entry point is scoped only when every record it authorizes is. A scoped entry point's exposure on a tenanted resource gets `in_current_tenant & ...`, with the authorize call's line in its basis. Unscoped and unknown change nothing, so the reading only removes false counterexamples, never findings it cannot back.
- **verify_authorized.** An action is exempt when the app declares `after_action :verify_authorized` somewhere in the controller's chain but not for that action, or a `skip_after_action :verify_authorized` applies; an unchecked request there is excused like `allow_unchecked` and listed under coverage. A controller that never declares it says nothing, so its unchecked requests still fail.
- **Gumroad.** Same stamps and terms as step 1, with every `allow_unchecked` line removed: on both checkouts, the gate's real bug remains and its data-side false positive is gone (`Settings::Profile::ProductsController#show` loads through `current_seller.products`), so 1 counterexample in 14 checks; four of the five `allow_unchecked` lines are now read from `PUBLIC_ACTIONS`, and the fifth stays (that controller declares no `verify_authorized`). With step 1's rule fix, no counterexample.
- **Routes** (second half). When the test process exits, the Railtie records the app's routes into the run's stamp file as `route` lines (`Collectors::Routes`; loading Rails 8's lazy routes then, if no request did, so a test never sees them loaded early). Engine routes and redirects, which name no controller, are skipped.
- **Routes no test reached** (no stamp and no unchecked request). Each authorize call is resolved to a rule: the policy from `policy_class:` (Pundit) or `with:` (Action Policy), else the record's model class plus `Policy` (`Link.find` is a Link; an association of the current tenant names a mapped resource by Rails' naming, so `current_seller.links` is a Link and Gumroad's `current_seller.products` is unknown), with Pundit's `[:admin, record]` namespace; the rule from the call's second argument or `to:`, else `<action>?`. A resolved rule the extractor read gives an exposure with the rule's code guard (and `in_current_tenant` when scoped), its basis starting "no test reached this route, read from code". What cannot be read is listed, never failed, since the code may authorize in ways Hallmark does not read: routes whose authorize call does not resolve, routes with no check call at all (`authorize`, `policy_scope`, `authorized_scope`, `skip_authorization` and the like) that are not exempt, and routes in controllers outside `app/controllers`; each list prints its first 12 names and a count.
- **Gumroad, routes** (fresh slice runs on both checkouts, 232 examples each, stamps and 1,102 routes byte-identical): 26 checks, 12 of them from routes no test reached, 4 counterexamples, identical on both. One is the gate's bug. Three are routes whose rule is role-only like it but whose shared filter checks the seller in controller code (`e404 unless product_accessible_by_current_user?(@product)`): false positives from authorization outside the policy, which Hallmark does not read (also seen on Forem). Four more, loaded with `Link.fetch(permalink, user: current_seller)`, led to reading tenant keywords as scoped. About 5.6 s for the whole run (CLI), 4.9 s (sidecar).
- **Checks in controller code** (added Oct 19, 2026, for the three false positives above). Before the entry point's first authorize call (in the `before_action` callbacks, then the action, and the argument-less helpers they call as statements, four levels down), a top-level way out guarded by a condition is read as a check: `e404 unless cond`, `if cond; head :forbidden; end` with no `else`, `cond || e404`, `redirect_to ... and return unless cond`. What ends the request depends on where the statement is: a `raise` (or a helper whose body raises, as Gumroad's `e404`) anywhere; in a callback also `head`, `render` or a redirect, since Rails halts the chain once a callback renders; in the action a `return` or `... and return`. A way out after the authorize call is the action's own logic (Gumroad's are validation errors and a redirect for bundles), and one inside a branch or a block may not run, so neither is read. The condition goes through the policies' `MethodTranslator` (`#expression`), helpers read in place with their arguments bound, under renames from controller names to the policy's: the authorized record's variable (`@product`, or a local) to `record`, the current tenant reader (`current_tenant ..., controller:`) to the policy's current tenant, and the signed-in user reader (the new `principal ..., controller:`, default `:current_user`; Gumroad's is `:logged_in_user`, what `pundit_user` passes) to the policy's user. `record.present?` is now a seeded term (true; `nil?` and `blank?` false). A check counts when its guard reads the record or reads exactly (`head :forbidden unless current_user&.staff?`); others (`return unless request.xhr?`) are skipped. Its lower bound is ANDed into the exposure (docs/adr/0003), with the line in the basis ("checked in the controller (file:line)") and its opaque calls listed under coverage. When that leaves the exposure nothing certain (`redirect_to ... unless @link.previewable?`), the entry point is not checked and is listed under coverage ("Entry points not checked"), as a rule that never allows is: a pass would claim a check that never ran.
- **Gumroad, controller checks** (stamps and routes of the run above, mapping plus `principal ..., controller: :logged_in_user`): `fetch_product_and_enforce_access` reads as `in_current_tenant | permitted` on eight entry points (`LinksController#publish`, `#unpublish`, `#release_preorder`, `#update`, `#update_sections`, `#disable_downloads_for_all_files`, and the same helper in `ProductFilesUtilityController`'s own filter on two more). The three false positives are gone and the gate's bug stays: 1 counterexample in 26 checks, identical on both checkouts and both backends apart from the opaque-call text in `Products::Archived::LinkPolicy`, as before. Without the user reader the collaborator half is opaque and the result is the same. A first cut that read every guarded way out, after the authorize call too, emptied seven exposures through validation and redirect conditions it could not read, which is why only those before it count. Memoizing `SourceIndex#ancestors` brought the whole run to about 4.4 s (CLI) and 4.0 s (sidecar), from 5.6 s and 4.9 s.
- **Grape moved to step 4** (decided Oct 19, 2026): GitLab's REST endpoints check DeclarativePolicy abilities, and their stamps carry no entry point, so they need a Grape collector as well as a reader; both belong with the DeclarativePolicy front end.
- **Known limits.** Checks in controller code after the authorize call, inside a branch, in an `if` with an `else`, or behind a call with arguments; a way out through a helper that renders, read only in a callback; a filter given as a block or lambda, an association whose name is not the resource's (`products` for `Link`), and an authorize call in a concern outside `app/controllers` read as unknown. Policy lookup is Pundit's naming; Action Policy's lookup through the controller's namespace is not modeled.

**The shipped DeclarativePolicy front end** (phase 2 step 4, done Oct 19, 2026):

- **Reading** (`SourceIndex`, its DeclarativePolicy half in `extractor/declarative_index.rb`): `condition(:x, scope:) { ... }` with a preceding `with_options scope:` or `with_scope`; `rule { ... }.enable`, `.prevent`, `.prevent_all` and `.policy do ... end`; `delegate { @subject.x }`; `overrides`; `prepended do` and `included do` blocks; and GitLab's `X.prepend_mod_with("X")`, which prepends `EE::X` from `ee/app/policies` (now read too). Ability lists built by class methods (`prevent(*create_read_update_admin_destroy(:pipeline))`, `class_methods do`, constants such as `READONLY_ABILITIES`) are evaluated, once the whole tree is indexed. Modules named `*Policy` are not policies of their own.
- **Translating** (`DeclarativeTranslator`): an ability is the OR of its enabling rules' conditions AND NOT the OR of its preventing ones (`prevent_all` included), with each delegate's rules joining in on the delegated subject unless `overrides` drops the ability; a delegate Hallmark cannot follow is an opaque prevent. Rule blocks read `&`, `|`, `~`, `can?(:other)` and condition names; a condition is the mapping's `term` for `"Policy#name"` or `"name"`, else its block body through the method translator with the subject renamed (`@subject`, `subject`, `alias_method ..., :subject`, and readers such as `def project = @subject` read as `record`, or `record.project` inside a delegate, so terms name what the subject is to the checked record). `anonymous` and `default` are the gem's own conditions. DeclarativePolicy abilities have no naming convention, so the abilities read are those `rule ..., op:` declares, plus any a stamp or a Grape endpoint names.
- **Hazards** (lints, which fail `hallmark check` and `hallmark rules`): D4, `&&`, `||` or `!` in a rule block (conditions are always truthy objects, so the guard keeps Ruby's meaning: `a && b` is `b`); D3, a condition cached at a scope that leaves out what its body reads (`with_scope :subject` reading `@user`; the gem's cache key for a `:subject` condition has no user in it).
- **Record flags and conditional grants** (the container question): `resource ..., flags: %i[project_public public_builds], public_when: flag(:project_public) & flag(:public_builds)` gives a record named boolean attributes (fields of one `RecordFlags` atom in the model, so witnesses name them: "with project_public and without public_builds") and defines its publicity over them; `grant :guest, :read, "Ci::PipelineSchedule", when: flag(:public_builds)` covers only records with the flag. A check on a container (GitLab's schedules page checks the `Project`) maps the container with the contained records' flags and publicity.
- **Grape** (moved from step 3): `Collectors::GrapeHook` prepends `Grape::Endpoint#run` and names the entry point "VERB /path" from the route's origin without the API prefix or version; `Extractor::GrapeEndpoints` reads `lib/api` and `app/api` statically, names endpoints the same way from `resource`/`namespace`/`route_param` blocks, and collects `authorize!(:ability, subject)` and `can?(user, :ability, subject)` in endpoint blocks and the helpers they call (`helpers do` blocks, modules named `*Helpers`), resolving the subject by its reader's name (`user_project` is a Project, `pipeline_schedule` a `Ci::PipelineSchedule`). Endpoints no test reached become exposures as unreached Rails routes do. Threat 10 is not flagged for Grape yet.
- **`hallmark rules FILE [POLICY...]`** checks each rule on its own from code and any recorded stamps, as the RSpec matchers do; exit 1 on a counterexample or a hazard, else 2 on an unknown.
- **GitLab** (mapping private): from code alone at `7ce3a7d`, `read_pipeline_schedule` gives an anonymous visitor a schedule of a public project without public pipelines, on both policies; at `c1a85e83ac3` there is no counterexample within scope 5. With the phase 1 stamps and the fix run's stamps, `hallmark check` has 19 checks (REST endpoints read from `lib/api`, the schedules controller, GraphQL): 19 counterexamples before the fix, all the one bug, none after, about 4 s per run, identical on the sidecar. The controller checks, blind in phase 1, now see it. The mapping writes the conditions Hallmark cannot read as `term`s, each a stated assumption (internal projects, external users, job tokens, auditors, bots, IP and SSO restrictions read as never holding). Three D3 hazards in GitLab's policies are triaged privately.
- **Forem**: `ArticlePolicy#update?` and `#destroy?` from code alone (two `term` lines) give Forem's finding; with the draft fix's policy change, no counterexample.
- **Known limits.** Global abilities and headless policies are still class-level and not modeled. Conditions whose names are built at run time (``condition(:"#{f}_disabled")``) need terms. `can?(:x, other_subject)` is opaque.

**The shipped SARIF** (phase 2 step 5, done Oct 19, 2026):

- `hallmark check --sarif OUT FILE...` also writes a SARIF 2.1.0 log (`Hallmark::Sarif`) of what fails the check: counterexamples, unchecked entry points (threat 10), drift and the D3 and D4 hazards, each its own rule (`hallmark/counterexample`, `hallmark/unchecked`, `hallmark/drift`, `hallmark/D3`, `hallmark/D4`, all level `error`, since each fails the build). Coverage is left out.
- **Locations**, relative to the app root: an exposure now carries `locations` (`Exposure#locations`), its entry point's first authorize call or Grape endpoint, then the rules' code and the controller's own checks; the first is the result's location and the rest are related locations. An unchecked entry point points at its action's `def` (`Controllers#action_location`), drift at the rule, a hazard at its condition or rule. A result with no line in the app's code (a hand-declared exposure) points at the mapping file.
- `partialFingerprints` (`hallmark/v1`, a digest of the rule and the check, entry point or drift key) keep a result's identity across runs.
- **Checked:** the GitLab, Gumroad and Storefront logs validate against the OASIS SARIF 2.1.0 schema. On GitLab, 22 results (19 counterexamples at REST endpoints, the schedules controller and GraphQL, each with the policy rule as a related location, and the 3 hazards); on Gumroad, F6 at `BundlesController#show`'s authorize call and the one unchecked action at its `def`.
- **Open:** GitLab's security dashboard reads its own report format, not SARIF (open question below).

**The shipped op inference** (after the phase 2 gate, done Oct 21, 2026; the gate's largest source of rule-level false positives was view and form rules named after the page, which the old convention called writes):

- **Order** (`Hallmark::Ops#fetch`): `rule ..., op:`; then the name: `index?`, `show?`, `new?`, `edit?`, `preview?`, `paged?`, `statistics?`, `stats?`, `overview?`, `search?`, `feed?`, `export?`, `download?`, `pdf?`, names starting `index_`, `show_`, `new_`, `edit_`, `preview_`, `export_` or `download_`, and names ending `_count`, `_stats`, `_statistics`, `_overview`, `_preview` or `_chart` read; then the routes: a rule reads when every route that reaches it is a GET or HEAD (and at least one does); otherwise a `?` rule writes and any other name needs `rule ..., op:`. `_collections` is not a read suffix, since `add_collections?` writes; Mastodon's `index_collections?` reads by its prefix.
- **Verbs only ever make a rule read.** A request's verb says what the request does, not what it does to the record the rule checks: Mastodon's reblog is a POST that checks `show?` on the status it reblogs. So a read name stays a read whatever the verbs, and a rule reached by any other verb (or by a route open to every verb) keeps the default.
- **Routes:** those the run recorded (`Collectors::Routes`), else those read from `config/routes.rb` and the files it `draw`s (`Extractor::RoutesFile`, Prism, never loading the app): verb calls with `to:`, `controller:`/`action:` or a bare name in a controller's scope, `"path" => "c#a"`, `match ..., via:`, `root`, `resources`/`resource` with `only:`, `except:`, `controller:`, `module:` and `path:`, `namespace`, `scope`, `controller ... do`, `member`, `collection`, concerns and `draw`; controller names camelize with the acronyms the app's initializers declare (Mastodon's `ActivityPub`). Redirects, mounted engines and routes built in loops are skipped, and paths are approximate. Static routes feed op inference only; route exposures still come from recorded routes.
- **Rules reached:** a route reaches a rule through a stamp naming its entry point, or through its action's authorize calls as `Extractor::Controllers` reads them (Grape entry points carry their verb in their name). A call whose record class the reader cannot tell names the policy by the record's variable, as Pundit does (`authorize @event` checks `EventPolicy`; `Controllers::Authorization#named_policy`, read by `Ops` only, since a wrong guess there can only miss a read); a call it cannot tie to any policy counts against every rule of its name. The unit's basis says when routes made a rule read ("read: only GET requests reach it (EventsController#ledger)").
- **Collectors** know no routes, so a stamp's op-dependent facts (`granted`, `permitted`) use the op from the mapping and the name (`Ops.named`, `Mapping#op_for`). A rule the routes make read on a resource whose `permits:` gives only some ops may then carry a `permitted` fact for the other op (not seen on the gate apps).
- **Hints:** a counterexample on a guard with no role and no ownership suggests `public_action` for its rules (with `audience: :signed_in` when the guard checks sign-in and the witness is signed in); an owner with no role in the record's tenant suggests `owner_outside_tenant:` (before the cross-tenant hint, since the owner is the likelier intent).
- **Checked:** `hallmark rules` reruns on HCB and Mastodon, before and after, are in their private logs. On HCB the inference alone reads most of the 49 view rules the gate mapping had declared as reads by hand.

**The shipped hot path** (phase 3 step 1, done Oct 21, 2026):

- **Benchmark.** `rake bench` (`bench/hot_path.rb`) runs six scenarios on the test shop: a Pundit rule called directly, a Pundit `authorize` outside a request, an Action Policy `apply`, a DeclarativePolicy `allowed?`, a Pundit `authorize` inside a Rails controller request, and five DeclarativePolicy checks inside one request (as a GitLab page makes many). Each runs bare (Hallmark not installed), then installed, cycling every iteration through switched off, on but not sampled, and on, so the three see the same noise. A first harness subtracted the bare median from each call; a Rails request's own tail swings by tens of microseconds between runs, so its p99 came out anywhere from 30 to 92 µs, and once as a negative difference. Time spent in mapping readers (the app's code: the shop's are in memory, a real app's are often queries) is clocked and reported apart from Hallmark's own work. Timed loops run with GC off in batches of 1,000, and allocations are counted process-wide, so the flusher thread's work counts.
- **Measured** (Apple M4 Max, Ruby 3.4.10 without YJIT, 20,000 calls per state; microseconds added per call, own work less readers, p50 / p99):

  | Scenario | Before | After | Objects before / after | Not sampled |
  | --- | --- | --- | --- | --- |
  | Pundit rule called directly | 4.9 / 8.8 to 9.8 | 2.8 to 3.0 / 8.3 to 11.1 | 38 / 11 | 0.4 / 0.7, 5 objects |
  | Pundit `authorize`, no request | 6.0 / 7.8 to 8.5 | 3.3 / 5.2 to 5.4 | 40 / 14 | 0.4 / 0.5, 6 objects |
  | Action Policy `apply` | 5.4 / 7.5 to 7.7 | 3.0 / 4.9 to 6.9 | 36 / 7 | 0.3 / 0.3 to 0.8, 1 object |
  | DeclarativePolicy `allowed?` | 5.3 / 7.0 to 9.5 | 2.8 / 3.7 to 4.3 | 31 / 7 | 0.0 / 0.2, 2 objects |
  | Pundit request (one decision) | 10.5 to 10.6 / 16.0 to 17.3 | 8.5 to 8.7 / 10.3 to 10.5 | 50 / 26 | 1.5 / 0.0, 15 objects |
  | Five DeclarativePolicy checks in a request | 30.5 to 30.9 / 69.5 to 69.9 | 18.5 to 18.8 / 23.4 to 25.1 | 155 / 17 | 1.0 to 1.3 / 0.5 to 1.0, 10 objects |

  Readers took 1.7 to 2.5 µs per decision before and 1.7 to 1.8 after; for five checks in a request, 12 µs before and 5 after. On top of the request rows, the installed `around_action` costs 4 to 6 µs per request whether or not anything is stamped (the bench's "idle" column). Budget: under 20 µs p99 per sampled decision, met in every scenario, the request ones included. "Zero allocations beyond the event" is not met: per decision the event is the Stamp and its role lists, and the rest are the readers' own objects and the hooks' argument lists (Pundit's rule wrapper takes `*args, **kwargs, &block`). The gate measures the same on a real app's requests, where readers query the database.
- **What changed.** Whether to stamp is decided before any fact is read: once per request in `Collectors.within_entry_point` (all of a request's decisions are stamped or none, and an entry point inside another keeps the outer one's choice), once per decision outside a request (`Collectors.recording?`). A decision not sampled still marks its request as checked, and an unchecked request not sampled is not flagged. `Collectors.install!(sample_rate:)` takes the share (the configuration setting comes with the modes, step 2). A request reads each user's roles in each tenant, and outside tenants, once (`Request#roles`, by identity), and a decision whose record lives in the current tenant reads the roles there once; before, every decision read them twice. `Facts` fills the Stamp in place instead of merging Hashes, caches what the mapping fixes (which classes are the principal, each class's resource, each rule's op), and takes a Symbol rule's name without copying it; Pundit's `authorize` builds its policy for the stamp only when the decision is sampled. `StampStore.new(capacity:)` bounds the queue: a full one drops the event and counts it (`#dropped`) rather than wait or grow; without a capacity, as in test mode, nothing is dropped. The set of stamps already written is cleared at 100,000 entries, which only lets a later duplicate through (`StampSet` dedupes on reading).
- **Known limit.** A request that changes a user's roles and then authorizes (accepting an invitation, then opening the team page) is stamped with the roles read first in that request. A test suite that hits it would see drift or an inferred guard wider than the rule; reading roles afresh after a membership write belongs with the revocation collector (step 9), which watches those writes.

**The shipped live modes** (phase 3 step 2, done Oct 21, 2026):

- **Modes.** `HALLMARK_MODE` (or `c.mode` before boot) takes `shadow` and `sampled` beside `test` and `off`; both collect in any Rails environment (`Configuration::COLLECTING`). The share of requests stamped is `c.sample_rate` or `HALLMARK_SAMPLE`, else 1.0 in `test` and `shadow` and 0.01 in `sampled` (`Configuration#sample_rate_for`), passed to `Collectors.install!(sample_rate:)` from step 1. A live store is bounded (`LIVE_CAPACITY`, 10,000 waiting events, dropped and counted beyond that); a test store is not. The Railtie builds the store with `Configuration#stamp_store(mode, root)`.
- **Routes in a live process** are recorded when Rails loads them, through the `after_routes_loaded` load hook (Rails 7.1 and later): at boot for an app that eager loads, as production does, so before a forking server forks; on first use otherwise. Recording them in `after_initialize`, as first written, recorded nothing: the app is not yet `initialized?` there, so `reload_routes_unless_loaded` does not load them (found by the Railtie test). Older Rails records them at exit, as test mode does.
- **Sinks** (`Hallmark::Sinks`): the flusher thread writes each new line through `write(line, run)`, with `flush` and `after_fork` optional. `Sinks::File` is the JSONL file per run and process, unchanged; `Sinks::RedisStream` wraps the app's own connection, redis-rb (`xadd`, with `maxlen:` and `approximate:`) or redis-client (`call("XADD", ..., "MAXLEN", "~", ...)`), with fields `run` and `line`, so Hallmark depends on neither; a callable gets the line, or the line and the run (`Sinks.build`, behind `c.sink =`). A sink that raises loses that line, counted in `StampStore#failed`, warns once per kind of error, and leaves the flusher running. `StampStore#path` is nil for a sink other than the file.
- **Run naming.** Collectors write the run `c.run` names (`HALLMARK_RUN`), else in a live mode the deploy's revision (a `REVISION` file in the app root, then `HEROKU_SLUG_COMMIT`, then `GIT_SHA`), else the time, with anything outside `[A-Za-z0-9_]` replaced by `_` (`Configuration#write_run`). Every process of a deploy then writes the same run; a test suite stays a run of its own.
- **Ids** (`docs/adr/0004`). With `c.ids = true` or `HALLMARK_IDS=on`, in a live mode only (test mode raises), and a key of at least 32 characters (`c.id_key`, `HALLMARK_ID_KEY`), the store records ids: the collectors capture `Example.ref` ("Class:id", nil for an object with no id) for the user, the record and the current tenant, only for a sampled decision and only when the store asks (`StampStore#ids?`). The flusher hashes them (HMAC-SHA256, hex) the first time the process writes that stamp, as `"example"` on its line; repeats and raw ids are never written. `StampSet#examples` maps each stamp to the example it was first read with. Printing an example beside a finding needs to know which stamp led to it, which `hallmark watch` does (step 3, "The shipped watch"); `hallmark check`'s findings come from guards, not single stamps, so it prints none.
- **Not measured on a real app yet.** The shop's readers are in memory; step 10 runs Gumroad in shadow mode.

**The shipped watch** (phase 3 step 3, done Oct 21, 2026):

- **Baseline** (`Hallmark::Baseline`, `hallmark check --baseline OUT FILE...`): one self-contained JSON file per build, format 1. It holds the Hallmark and Alloy versions and the scope, a SHA-256 of the mapping files' bytes, the run its stamps came from (`c.run`, else the newest run's name, `StampSet.run_of`), every stamp, unchecked and route line of that run (examples left out; a test run has none), and per check its name, entry point, op, resource, digest and verdict (`counterexample`, `none` or `unknown`), plus the unchecked entry points and drift keys (`Drift#key`, rule, decision and facts, also SARIF's identity for drift) that failed. Policy-DSL hazards are not in it: they come from code, which is CI's to report.
- **Digest** (`Exposure#digest(mapping)`): SHA-256 of what the model builder renders for one exposure and depends on: the check name, op, resource, the guard as printed, the sorted rules, and the public action the mapping gives them (audience and condition). Baseline and watch compute it the same way, so an equal digest is the same check.
- **Watch** (`Hallmark::Watch`, `hallmark watch --baseline FILE MAPPING`): seeds its stamps from the baseline's lines, so its guards start equal to CI's (`Watch::Stamps` keeps them, in the order first read, and knows which are live). Each batch of new lines is folded in and inference runs again over all stamps, with the extractor loaded once; exposures whose digest differs from the last one checked (the baseline's first) go to the solver in one `Analysis` of just those exposures, against the same mapping (whose facts do not depend on which exposures are present). The first batch always runs, so a stale baseline or policy code changed since CI is checked at once; later polls with no new line do nothing. Inference is not incremental: on a few hundred stamps it is cheap Ruby, and keeping it whole keeps it equal to `hallmark check`'s.
- **What is new.** A counterexample on a check that was not failing in the baseline or an earlier batch; an unchecked entry point or drift key the baseline does not list (each reported once). A counterexample on a check already failing is counted as "already known", even when its guard widened. A failing check that passes again is reported once as no longer failing (`ok ... no longer fails, no counterexample within scope N`), which is not a failure; failing again later is new again. An unknown is printed (`??`) and retried at the next batch whose new stamps touch the exposure (its entry point or one of its rules), and never counted as no counterexample.
- **Stale baseline.** When the mapping file's digest, the scope, the Hallmark version or the Alloy version differ from the baseline's, the watch warns once and checks every exposure in its first batch. It keeps the baseline's failing checks, unchecked entry points and drift as known, so CI's failures are not announced again after a mapping edit.
- **Sources** (`lib/hallmark/watch/`). `Watch::FileTail` tails the files of one run under `--stamps` (default `c.stamps`): `--run`, else `c.run`, else the newest run when its first file appears, kept from then on, so a later deploy needs a restart (or `--run`). It keeps a byte offset per file, reads complete lines only (a partial last line waits for its newline), rereads a file that shrank, and picks up a forked worker's new file at the next poll, every `--interval` seconds (default 2). `Watch::RedisTail` reads the stream `Sinks::RedisStream` writes with XREAD (`--stream`, default `hallmark:stamps`), starting after the stream's last entry (XREVRANGE, so nothing written between two reads is lost) or at its first with `--from-start`, blocking up to the interval, and keeps the lines of the run (`--run` or `HALLMARK_RUN`, required unless `--all-runs`). It speaks redis-rb (`xread`, `xrevrange`) and redis-client (`call`, `blocking_call`, RESP2 or RESP3 answers); `RedisTail.connect(url)` requires redis-client, else redis, only on that path, so neither is a dependency. A line that is not JSON is skipped with a warning.
- **Output.** Text by default: a header naming the baseline's run, its checks and failures and the source, each event in `hallmark check`'s wording (`Report.finding_lines`, `Report.drift_lines`, `Report.unknown_line`), and one summary line per batch (new stamps, checks run, new counterexamples, already known, none within scope, unknown, no longer failing, new unchecked entry points and drift). `--json` writes one object per event instead (`type` `finding`, `unchecked`, `drift`, `resolved` or `unknown`, with the check, entry point, op and resource, and for a finding the guard, basis, message, pattern, hint and example). `--sarif FILE` rewrites a SARIF log of everything new since the start after each batch (`Watch::Log`, which `Sarif` reads as it reads a report). `c.on_finding = ->(event) { ... }` is called once per new event except unknowns, with a `Watch::Event` (`type`, `data`, `lines`, `to_h`); an exception in it is warned about and the watch goes on.
- **Examples.** Each new finding prints the first-seen example of the live allow-stamps of its rules on its resource, those at its entry point first: `first seen as user h:<first 12 hex>, record h:..., tenant h:...`, leaving out what had no id. Only the watch prints them.
- **Running.** `--once` runs one batch over what is there and exits 1 on any new finding, unchecked entry point or drift, else 2 on an unknown, else 0 (`Report.exit_code`'s order). Otherwise it polls until SIGINT or SIGTERM (a self-pipe wakes the wait), restores the previous handlers and exits 0; a batch that raises a Hallmark error is warned about and the next one runs. The solver is the sidecar, warm for the life of the process, unless `--solver`, `HALLMARK_SOLVER` or `c.solver` picks one; the CLI, with a one-line warning, when the sidecar is not built. It is closed on exit either way.
- **Tests.** Unit tests on hand-built stamps and `FixtureSolver` (`test/watch_test.rb`, `test/baseline_test.rb`): the M2 stamp (the current seller's admin updating another seller's link) is the one new finding and the only check sent, with its example; nothing is sent on a poll with no new line; already known, no longer failing, unknown retries, unchecked and drift novelty, a stale baseline, JSON, SARIF, `on_finding`, partial lines, forked workers, other runs, and both Redis client shapes. End to end (`test/watch_end_to_end_test.rb`): the shop app boots in a child process in test mode (the baseline's run) and in shadow mode with hashed ids, serving the cross-seller update; in process on `FixtureSolver`, then `bin/hallmark check --baseline` and `bin/hallmark watch --once` on the CLI backend (one finding, its example, exit 1), then on the sidecar, where one process serves both batches.
- **Not built.** Running as a daemon or service unit, guard mode, and field-level and GraphQL exposures (steps 4 to 6). The run a file tail follows is fixed once found, and a watch that has run for long holds every stamp it has read; neither has been measured on a real app (step 10's gate runs Gumroad in shadow mode).

## First real-app run: Gumroad (Pundit)

On Oct 16, 2026 Hallmark ran on original Gumroad, still on Pundit, at `b6c62aa` (`main`), scoped to `LinkPolicy` and the ten controllers that authorize a `Link` with it. This is not a gate result (Forem is the Pundit gate app); it is the Pundit half of the later differential check against the Action Policy port, chosen first because Gumroad's mapping was already designed and GitLab needs unbuilt group-to-project inheritance. The findings log is private (see the disclosure rule under "Roadmap"); this section records only what it taught Hallmark.

- **Run.** Gumroad's own `link_policy_spec.rb` plus 21 controller spec files, 232 examples, with the collectors on and no Gumroad code changed (a Gemfile path entry and `config/hallmark.rb` only). 81 stamps, 63 of them from the policy spec. `hallmark check` built 14 checks: every one had no counterexample within scope 5 and none was unknown; the whole run took 2.4 to 2.7 s on the CLI and 1.9 s on a cold sidecar, and each check 69 to 84 ms on a warm sidecar (Apple M4 Max). Five entry points were flagged as unchecked (threat 10); all were intended (public product pages and a utility that reads no record) and became `allow_unchecked` lines. A coverage gap pointed to one more rule, confirmed with a probe spec; it is triaged in the log.
- **Setup notes.** Gumroad's specs need its Docker services (MySQL 8.4, Redis, Elasticsearch, DynamoDB, MinIO) and `CI=true`: without eager loading, Rails 8's lazy routes break Devise's `sign_in` in controller specs. 36 examples fail locally with or without Hallmark (no Stripe test credentials for `create(:purchase)`, no Vite build), which costs the stamps of one entry point (`Bundles::ContentController#update`).

What the run found in Hallmark, fixed in the same change:

- **The Pundit collector changed app behavior.** It reassigned `authorize`'s `query` parameter before a bare `super`, so Pundit raised with `"edit?"` instead of `:edit?`; Gumroad's error handler compares `exception.query == "edit?"`, and one action answered 302 instead of 401. A collector must pass the caller's arguments through untouched; `test/collectors/pundit_test.rb` now checks it.
- **Policy specs were invisible.** Most of Gumroad's role evidence lives in `permit` calls (owner, marketing, collaborator, cross-seller denies); controller specs sign in only as an admin of the seller. The Pundit collector now stamps `permit`.
- **No pattern for collaborators.** A collaborator edits another seller's product with no role there; the inferred guard was `role(:owner, tenant: :current)` alone, a false counterexample. Explicit permission on a record (`permits:`, `permitted`, `Permit`) is now in the catalog and the DSL.
- **Witnesses held undeclared roles.** Adding a signature to the catalog changed which counterexample the solver returned, and the new ones held anonymous `Role` atoms inheriting a declared role, or `Admin` inside a seller. Roles, hierarchy, platform roles and `Admin` are pinned now ("The shipped encoding").

Gaps it showed and left open:

- **Data side (known).** An entry point that loads through the current seller (`current_seller.products.find_by_external_id!`) inherits its rule's cross-seller allows from other entry points; with the probe's stamp this gave one false counterexample. The data-side collector would fix it.
- **Untested regions stay silent.** Every check passed on Gumroad's own stamps; the one real issue came from reading the "not observed" section, as ADR 0002 intends. The phase 2 extractor reading the rule would report it directly.
- **Public actions.** Pundit apps list the actions that skip `verify_authorized`; Hallmark could read that list (statically, in phase 2) instead of needing `allow_unchecked`.
- **Class-level rules** (`authorize Link`, 9 of `LinkPolicy`'s rules here) are not modeled.
- **Guard printing.** Inferred guards factor out only literals every allow-stamp shares, so a guard prints as `(in_current_tenant & role(:admin, ...)) | (in_current_tenant & role(:marketing, ...)) | ...` rather than `in_current_tenant & (...)`.
- **Stubbed policies.** A controller spec that replaces the policy with an `instance_double` drops its stamp with a warning; harmless, but the warning reads like an error.
- **Collaborator witnesses** also carry the role the collaborator held in their own account (`permitted & role(:owner, tenant: :current)`), which is true of the stamp but irrelevant to the decision.

## Phase 1 gate run: Forem (Pundit)

On Oct 18, 2026 Hallmark ran on Forem at `b042765` (`main`, Oct 16, 2026; Pundit 2.3.1, Rolify 6.0.1, Rails 8.0.5, Ruby 3.3.0), scoped to `ArticlePolicy` and `OrganizationPolicy` and the controllers that authorize an `Article` or an `Organization` with them; organizations are the tenants. Forem's history has no past authorization fix inside a Pundit policy that the catalog can see (its policy fixes are suspension rules, which need the unbuilt `c.restrict`; forem/forem#23899's membership bug lived in controller code), so the gate's bug had to be live. The findings log is private (disclosure rule under "Roadmap"); this section records only what the run taught Hallmark.

- **Run.** Two policy specs, 15 request spec files and one probe spec, 790 examples, 0 failures with or without the collectors, in Docker (Forem's CI images and steps). 111 stamps. `hallmark check` built 33 checks: 7 counterexamples, all one live finding (triaged in the log, accepted as the gate's bug, reported to Forem's security team on Oct 19, 2026), the rest with no counterexample within scope 5, none unknown; the whole run took 2.9 s on the CLI and 2.4 s on a cold sidecar, with identical findings. 25 entry points were flagged as unchecked (threat 10), all intended (public API reads, author-scoped API writes, personal analytics, a membership action authorized by hand) and now `allow_unchecked`.
- **Rerun with the follow-ups merged** (same day, same commit, mapping and environment; Hallmark with the `outside_tenants` guard term and the direct-call Pundit wrapper below). 791 examples (the probe gained an API case), 0 failures; 299 stamps, the policy specs now included. 33 checks: 8 counterexamples, the same live finding on the same 7 entry points and one catalog gap (below), none unknown; 3.2 s on the CLI, 2.4 s on the sidecar, identical findings. With a draft fix for the finding applied (it also authorizes the API update) and a probe asserting the fixed behavior: 801 examples, 0 failures, 314 stamps, **1 counterexample in 35 checks**, the catalog gap alone, same times. This is the detect-then-fix comparison the GitLab run made with its historical fix.
- **Rerun with the controller-hook fix** (Oct 19, 2026; see "The shipped collectors", threat 10). Both columns again, same commit, mapping and environment: the same 791 and 801 examples, stamps byte-identical to the previous rerun's, identical reports (8 counterexamples in 33 checks, 1 in 35 with the draft fix), none unknown, at most 3.7 s per run. Forem does not eager load in tests, so its controllers always ran the hook before their own filters. Forem still meets the gate's criteria.
- **Setup notes.** Hallmark loads through a local initializer (`HALLMARK_LIB`), as on GitLab, so Forem's Gemfile is untouched. Forem makes Rolify's `has_role?` private, so the mapping reads roles through its `Authorizer`.

What the run found in Hallmark, fixed in the same change:

- **Records with an optional tenant.** A personal article has no organization. `resource ..., tenant_optional: true` ("The shipped encoding").
- **Owner allows on records outside tenants.** Allow-stamps on personal articles inferred a bare `owner` guard, which the model then applied to articles in an organization, so a fix to the app could not clear the check. Inference now adds the guard term `outside_tenants` for a record with no tenant ("The shipped collectors").
- **Policy specs that call rules directly.** Forem's policy specs call `policy.public_send(:update?)` (pundit-matchers' `permit_actions` works the same way), so neither `authorize` nor `permit` ran and the first run's stamps came from request specs only. The Pundit collector now wraps each policy class's rules ("The shipped collectors").
- **The wrapper broke RSpec stubs.** Its first version put the wrappers in a module prepended to each policy class, and RSpec refuses `allow_any_instance_of(ArticlePolicy).to receive(...)` on a method a prepended module defines, so one Forem example failed with the collectors on. The wrappers now replace the rules on the class itself.
- **Ruby 3.3.0.** The same wrapper forwarded an anonymous block (`&`) from inside another block, a SyntaxError on Ruby 3.3.0 (3.3.1 and later accept it), so Forem failed to boot with the collectors on. The block is named now, and `lib/` is checked to parse on 3.2, 3.3.0 and 3.4.

Gaps it showed and left open:

- **Creating a record.** `OrganizationPolicy#create?` lets any signed-in user in good standing create an organization, which is intended, but the catalog has no pattern for creating a record (the creator becomes its admin only once it is saved), so the API's `create` reports a counterexample once the policy spec's allows are stamped. Seen in the rerun, identically before and after the fix.
- **Authorization outside Pundit.** Forem decides several organization questions with hand-written checks in controllers; the collectors see none of them.
- **Platform roles are all or nothing.** Super moderators may unpublish and retag any article but not edit it; mapped as a platform role, they may do anything.
- **Report wording.** With no `current_tenant` declared, witnesses still name "the current tenant" and suggest checking it (also seen on GitLab); the "intended pattern" line can name explicit permission when no resource is mapped with `permits:`. Fixed Oct 21, 2026: a witness's current tenant is left out unless the map block declares one (`current_tenant`) or the guard reads it, and the pattern follows the way the witness got in (as the owner, or through a role it holds) before what the guard and the mapping offer, naming a role grant ("Explicit permission (a grant to a role)") apart from a permit on a record ("Explicit permission on a record"), and "Public actions" for a guard with neither.

## Phase 1 gate run: Gumroad port (Action Policy)

On Oct 19, 2026 Hallmark ran on Gumroad ported to Action Policy (0.7.7), forked from `b6c62aa`, the commit of the first Pundit run, and on the original at the same commit: the Action Policy gate run and the differential check of the two adapters. The port is local (a worktree branch, not pushed) and follows Action Policy's migration guide in two commits plus one fix; Gumroad is MIT licensed, but its code stays out of this repository like every target app's. The findings log is private; this section records what the run taught Hallmark.

- **The port.** Phase 1 of the guide: action_policy replaces pundit, `ApplicationPolicy` includes Action Policy's core with `user` and `seller` as authorization context (`authorize :user, :seller, allow_nil: true`), and controllers keep calling `authorize` and `policy`, now shims over `authorize!` and `policy_for`. Phase 2: policies inherit `ActionPolicy::Base`, the logged-in check becomes a pre-check, controllers that only read a rule use `allowed_to?`. Pundit resolves `[:settings, :team, membership]` to `Settings::Team::TeamMembershipPolicy`, and Action Policy's lookup has no such form and prefers the caller's namespace, so the port carries a small finder reproducing Pundit's lookup and always passes `with:`. Two Pundit behaviors had to be kept by hand: a denied `authorize` counts for `verify_authorized` (one controller rescues the denial), and Gumroad's error handler compares the query as given (`"edit?"` from the action name redirects, `:edit?` passed as a Symbol answers 401). Policy specs keep the Pundit syntax (`action_policy/rspec/pundit_syntax`, with a `permit` taking Gumroad's context object), since they are the evidence the port kept behavior.
- **Evidence the port kept behavior.** All 56 policy spec files fail in exactly the same examples on both sides (648 examples, 111 failures from missing Stripe test credentials). Controllers, presenters, policies and channels (9,614 examples) did too, once the comparison found Pundit's controller helper `permitted_attributes` missing from the port (8 examples, one caller).
- **Differential check: passes.** The slice is run 2's (`LinkPolicy` and the ten controllers, 232 examples). The two adapters wrote byte-identical stamp files (159 stamps, 6 unchecked events) and `hallmark check` printed identical reports on both backends: 14 checks, no counterexample within scope 5, no unknown, 1.9 to 2.3 s for the whole run. With the first run's probe spec added, both report the same 2 counterexamples, the triaged real bug (current-tenant confusion in `LinkPolicy#show?`, no security impact found) and its known false positive.
- **Hallmark bug found.** The first pair of runs agreed with each other but not with the October 16 run: 8 checks and 3 unchecked entry points instead of 14 and none. The cause was the controller hook's position in the callback chain (see "The shipped collectors", threat 10), fixed with `prepend_around_action` and a test. Agreement between two adapters does not catch a bug in code they share; comparing with an earlier run did.
- **Gate: met.** Declared slice, pinned commit, every check under 10 s with no unknown, findings triaged (the port adds none), and a confirmed real bug: the slice's only one, which has no security impact found (its history holds no past authorization fix to reproduce). Decided Oct 19, 2026 that such a bug counts (see "Risks and open questions"), so Action Policy meets the gate.

## Phase 2 gate run (five apps)

Run Oct 19 to 21, 2026, on the three phase 1 apps at their pinned commits and two new ones, HCB (`a8c6c05`) and Mastodon (`5204e8a`). Decided Oct 19, 2026: bounded, tenancy-heavy slices (about 6 to 12 policies per app, not every policy); HCB and Mastodon as the new apps (both Pundit; rubygems.org's 59 scope classes are out of the catalog's reach); the new apps checked from code only, with a probe spec allowed to confirm a candidate. Findings logs are private, and live bugs are described here only in outline.

| App (library) | Checked | Counterexamples | Real bugs | Flaws, no impact | Catalog gaps | Mapping and op errors | Rules with opaque leaves | Max per check |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Gumroad (Pundit, and the Action Policy port) | 48 entry points (stamps, routes and code); 86 rules | 2 at entry points; 67 rules (see below) | 2 live (the phase 1 bug, and a new cross-seller read on a route no test reached, confirmed with a probe) | | | | 8% | 1.97 s |
| Forem (Pundit) | 18 entry points; 137 rules | 7 at entry points, all one bug; 24 rules | 1 live (the phase 1 finding, reported) | 1 | | 11 | 54% | 0.2 s |
| GitLab (DeclarativePolicy) | 19 entry points; 6 rules | 19 at entry points, all one bug; 4 rules | 1 historical (gitlab-org/gitlab!132952), none at the fix | 1 (unconfirmed) | 1 | | 0% | 0.63 s |
| HCB (Pundit) | 198 rules, code only | 18 | 0 | | 7 | 11 | 15% | 0.83 s |
| Mastodon (Pundit) | 43 rules, code only | 1 | 0 | | | 1 | 31% | 0.14 s |

- **Criteria.** Every phase 1 bug reproduced from code with no probe spec (Gumroad's from its own specs and its code; Forem's from `ArticlePolicy` alone; !132952 from `ProjectPolicy` alone, cleared at the fix); every finding triaged in the private logs; every check under 10 s with no unknown, on either backend. Met.
- **Rule level against entry points.** Gumroad's 67 rule counterexamples have one shape: the rule checks the user's role in the current seller and never that the record belongs to that seller. That is Gumroad's convention (controllers load records through `current_seller`), so they are not false positives at the rule level, but a Gumroad report reads at the entry points, where the controller's scoping is read and 2 remain, both real. `hallmark rules` suits apps whose rules check the record's own scope (HCB, Mastodon, GitLab); `hallmark check` with routes and controllers suits apps like Gumroad.
- **Hallmark gaps the gate found, all fixed.** A callback's branch on a `true` default parameter (`fetch_post(viewed_by_seller = true)`); stamps recorded before a resource's facts were mapped (now skipped and listed as stale under coverage); DeclarativePolicy delegates through a helper (`delegate { subject_container }`); Grape helpers called with arguments and abilities named by a helper (`read_project_ability`); "a OfferCode" in the report wording.
- **False positives.** At the entry points, none once those gaps were fixed. At the rule level the largest source is op errors: view and form rules named after the page (`index_collections?`, `edit?` on a form), which the read and write naming convention misreads. The catalog gaps are ownership without membership and intended public actions. All three fixed Oct 21, 2026 ("The shipped op inference", "The shipped encoding"); the reruns' counts are in the private logs.
- **Against SPACE** (23 bugs and 10 false positives over 30 apps, 2016): 4 confirmed real bugs over 5 apps, 0.8 per app against SPACE's 0.77, on mature, maintained apps (GitLab and Mastodon are heavily audited) rather than 2016-era apps with ad-hoc checks; one of the four is new and was found from a route no test reached. HCB and Mastodon yield none: both check access in the record's own scope consistently. Yield is not lower on comparable apps, so the extraction approach holds. Before phase 3: infer a rule's op better and add the two catalog patterns (both done Oct 21, 2026).
- **Gate: passed** (decided Oct 21, 2026, by Anthony). Phase 2 is done; phase 3 is next.

## Roadmap

The spike is deliberately small: shell out to the 6.2 CLI, hand-write the generated `.als` for one demo app, and prove the loop end to end before building the sidecar.

A working spike in two weeks, a usable gem by week 6. Weeks are estimates for one engineer.

| Phase | Weeks | Delivers | Exit gate | Status |
| --- | --- | --- | --- | --- |
| 0. Spike | 1 to 2 | CLI backend, `catalog.als`, one demo app | MediumClone bugs reproduced | Done Oct 15, 2026 |
| 1. Core gem | 3 to 6 | Tenant-aware DSL, collectors and stamp store, sidecar shim, RSpec matchers (in that order) | 3 apps, one per library (Pundit, Action Policy, DeclarativePolicy): each check under 10 s with no unknown, a triaged findings log, and one confirmed real bug per app | Deliverables built: tenant-aware catalog and DSL, then collectors, stamp store and Railtie, then the sidecar (Oct 15, 2026), then the RSpec matchers (Oct 16, 2026). Done Oct 19, 2026, when the gate passed on all three apps: first real-app run on Gumroad (Pundit, not a gate app) Oct 16, 2026; GitLab (DeclarativePolicy) run Oct 17, 2026 on pipeline schedules at the commit before gitlab-org/gitlab!132952: 9 checks in 1.7 s, no unknown, one counterexample (the historical bug), and none at the fix (`c1a85e83ac3`); GitLab meets the gate's criteria, with the controller checks blind (abilities checked on a container); Forem (Pundit) run Oct 18, 2026 on articles and organizations at `b042765`: 33 checks in 2.9 s, no unknown, 7 counterexamples from one live finding (private log), accepted as Forem's gate bug Oct 18, 2026, so Forem meets the gate's criteria; rerun with the follow-ups merged, the finding's counterexamples all go away under a draft fix; Action Policy (Gumroad ported from Pundit at `b6c62aa`) run Oct 19, 2026: 14 checks in 2.1 s, no unknown, stamps and findings identical to the Pundit original (the differential check passes), one real bug with no security impact found, counted for the gate (decided Oct 19, 2026), so Action Policy meets the gate and **phase 1's gate passed on Oct 19, 2026**; the run also found the controller hook running after `before_action`s (fixed); GitLab and Forem rerun with the fix Oct 19, 2026 gave identical stamps and reports, so both still meet the gate's criteria |
| 2. Extractor | 7 to 10 | Prism guards for Pundit and Action Policy, then DeclarativePolicy; static entry points (controllers, routes, record loading); drift reports; SARIF | Bug yield compared with SPACE, on five apps (see "Phase 2 plan") | Started Oct 19, 2026. Step 1 (extractor core, Pundit and Action Policy) done Oct 19, 2026: Gumroad's gate bug found from code with no probe spec, on both checkouts, and gone with a rule fix ("The shipped extractor"). Step 2 (drift) done Oct 19, 2026: none on Gumroad's step 1 inputs ("The shipped drift"). Step 3 (controllers and routes) done Oct 19, 2026: Gumroad's data-side false positive gone, four of its five `allow_unchecked` lines read from code, routes no test reached checked from code, and checks in controller code read before the authorize call, which removed Gumroad's three role-only false positives ("The shipped controllers"); Grape moved to step 4. Step 4 (DeclarativePolicy, Grape) done Oct 19, 2026: gitlab-org/gitlab!132952 found from policy code at `7ce3a7d` and cleared at the fix, Forem's finding from `ArticlePolicy` alone ("The shipped DeclarativePolicy front end"). Step 5 (SARIF) done Oct 19, 2026 ("The shipped SARIF"). Gate (step 6) run Oct 19 to 21, 2026 on Gumroad, Forem, GitLab, HCB and Mastodon: every phase 1 bug from code, every check under 2 s with no unknown, 4 confirmed real bugs (one new), 0.8 per app against SPACE's 0.77 ("Phase 2 gate run"); **passed Oct 21, 2026**, so phase 2 is done. The gate's two false-positive sources fixed Oct 21, 2026: op inference from names and route verbs ("The shipped op inference"), and the ownership without membership and public actions patterns ("The shipped encoding") |
| 3. Runtime and GraphQL | 11 to 17 | Hot-path benchmark, shadow and sampled modes with sinks and HMAC ids, `hallmark watch`, field-level mapping and `c.restrict`, GraphQL schema walk and tracing, list scopes (M5, G5), REST serializer fields, revocation (narrow) | Hot-path budget met in benchmark, plus shadow, GraphQL and field or list findings on gate apps (see "Phase 3 plan") | Planned Oct 21, 2026 ("Phase 3 plan"); the four additions to the original row (`c.restrict`, list scopes, serializer fields, HMAC ids) stretch it from 4 weeks to about 7. Step 1 (hot path and benchmark) done Oct 21, 2026: under 20 µs p99 per sampled decision on the test shop, from about 5 µs to 3 µs at the median and 31 to 50 objects to 7 to 26 ("The shipped hot path"). Step 2 (live modes, sinks, ids) done Oct 21, 2026 ("The shipped live modes"). Step 3 (baseline and `hallmark watch`) done Oct 21, 2026 ("The shipped watch") |
| 4. Hardening | 15 on | JRuby backend, native-image, CI integrations | | |

Phase 0 shipped as the gem skeleton: catalog, mapping and guard DSL with grants, model builder, CLI backend, witness decoder, and the MediumClone example with its fix. Two scope changes on Oct 15, 2026: the fact store (events deduped into stamps) joined phase 1, because the phase 1 collectors need somewhere to write; and field-level mapping moved from phase 4 to phase 2, because threats 4 and 11 and GraphQL G1 depend on it. On Oct 19, 2026 it moved again, with the GraphQL schema walk, to phase 3 ("Phase 2 plan" below).

Phase 1 decisions, Oct 15, 2026:

- **Order.** The tenant-aware catalog and DSL come first, driven by Gumroad, then collectors and the stamp store, then the sidecar, then matchers. One CLI run already costs one JVM start for all checks, so the sidecar is not on the gate's critical path.
- **Guards** are inferred from stamps, with hand-written overrides, until phase 2 extraction exists (see "Runtime modes and performance budget").
- **Gate, per app:** a declared slice (Gumroad: `LinkPolicy` and the controllers that call it); every check finishes under 10 s with no unknown; every finding triaged as a real bug, a catalog gap or a mapping error; the tested commit pinned; and at least one confirmed real bug. A real bug is one live at the pinned commit, or a past security fix reproduced at the commit before it (as MediumClone reproduces SPACE's bugs). A seeded bug never counts.
- **Disclosure.** Findings logs for third-party apps stay private. A live bug is reported through the project's security policy and published only after a fix or the policy's deadline; historical bugs may be published at once.
- **Differential check.** Original Gumroad (Pundit) and the Action Policy port run at the same commit as a test of both adapters; findings must match. It is a test, not one of the three gate apps. Phase 2's gate is the honest test of the whole idea: if extraction plus runtime facts finds fewer real bugs than SPACE did on comparable apps, revisit the extraction approach before investing in runtime modes.

Phase 2 plan, decided Oct 19, 2026:

- **Scope.** The GraphQL schema walk and field-level mapping move to phase 3, next to GraphQL tracing, so the GraphQL work lands in one phase; SPACE had no GraphQL, so the phase 2 gate does not need it. Phase 2 is the extractor, static entry points, drift and SARIF.
- **Prism** becomes a runtime dependency (`prism >= 1.2`), the second after `rexml`. Ruby 3.2 bundles none and Ruby 3.3.0 bundles prism 0.19, whose node API differs from 1.x. The extractor reads source files and never boots the app, so it runs on the host's Ruby whatever Ruby the app needs (GitLab's 3.1 included).
- **Bounds** (`docs/adr/0003`). A Ruby call the extractor cannot translate becomes an opaque leaf carrying its source and line. Opaque leaves never reach Alloy: the lower bound sets each to false where it is positive and true where it is negated (what the code allows whatever the call returns), the upper bound the opposite. Findings come from the lower bound only; what lies between the bounds is coverage ("depends on `<call>`"). A rule's checked guard is the hand-written one, else the extracted lower bound OR the inferred guard, both of which the app certainly allows.

Steps, in order:

0. **Phase 1 loose ends.** Fix CI (done Oct 19, 2026): every pipeline on `main` from Oct 17 failed in `lint`, because `srb tc` checked the gems CI installs under `.cache/bundle`, now ignored in `sorbet/config`; fix the Forem run's report wording (a witness naming the current tenant when none is declared, and an "intended pattern" line naming explicit permission when no resource has `permits:`; done Oct 21, 2026, see "Phase 1 gate run: Forem").
1. **Extractor core, Pundit and Action Policy front end, on Gumroad** (done Oct 19, 2026; "The shipped extractor"). `Hallmark::Extractor` parses `app/policies`, translates rule bodies (boolean operators, `if`/`unless`, early returns, sibling rules and private helpers inlined, `super`, `==` and `!=`) through a term table seeded from the mapping (`owner:`, `public_if:`, `tenant:` with `current_tenant`, platform roles, `permits:`) and the new `term "user.role_admin_for?(seller)", role(:admin, tenant: :current)` declaration. Rules no stamp shows become units too. `hallmark extract FILE` prints each rule's guard. Exit: Gumroad's F6 reported from its own specs with no probe spec, identically on the Action Policy port, and gone with the fix (the detect-then-fix demo).
2. **Drift** (done Oct 19, 2026; "The shipped drift"). A three-valued `Guard#evaluate` over a stamp's facts: an allow-stamp outside the upper bound, or a deny-stamp inside the lower bound, is drift, listed with the rule's source line; drift fails `hallmark check` (exit 1), as the "Runtime modes" table says. No drift on Gumroad's step 1 inputs; a deliberately wrong `term` shows it.
3. **Static entry points** (done Oct 19, 2026, "The shipped controllers"; Grape moved to step 4). Per controller action: `authorize` calls (in the body and in `before_action` callbacks), `skip_after_action :verify_authorized` and `skip_verify_authorized!` (replacing most `allow_unchecked` lines), and how the authorized record was loaded: through the current tenant (`current_seller.links.find`, which ANDs `in_current_tenant` into the exposure and closes most of the data-side gap) or not (`Link.find`). The Railtie dumps the routes at test boot, so routes no test reached still become exposures or threat 10 lines. Guarded ways out before the authorize call (`e404 unless product_accessible_by_current_user?(@product)`) read as checks ANDed into the exposure by their lower bound. Grape endpoints if they fit, else in step 4.
4. **DeclarativePolicy front end, on GitLab** (done Oct 19, 2026; "The shipped DeclarativePolicy front end"), with Grape endpoints (moved from step 3: a Grape collector naming the entry point, and a reader for `authorize!` inside endpoint blocks). `condition` bodies through step 1's translator or `term`; `rule { ... }.enable` and `.prevent`, `.policy do ... end`, `can?`, `delegate` and `overrides`; an ability is the OR of its enables and not the OR of its prevents, plus the delegate's rules unless overridden. Static lints D3 and D4. Settles the container-ability and global-ability questions below. Exit: gitlab-org/gitlab!132952 found at `7ce3a7d` from `ProjectPolicy` alone, none at `c1a85e83ac3`; Forem's finding found from `ArticlePolicy` alone.
5. **SARIF** (done Oct 19, 2026; "The shipped SARIF"). `hallmark check --sarif FILE` (SARIF 2.1.0): findings, drift, unchecked entry points and lints, located at the rule's `def` and the controller action. Coverage is left out.
6. **Gate** (run Oct 19 to 21, 2026; "Phase 2 gate run"). GitLab, Forem and Gumroad (Pundit and the port) at their pinned commits, each widened to a bounded, tenancy-heavy slice (decided Oct 19, 2026, instead of every policy), plus HCB and Mastodon (decided Oct 19, 2026), checked from code only. Every phase 1 bug reproduced from code with no probe spec; every finding triaged; every check under 10 s with no unknown; per app, a table of real bugs, false positives, catalog gaps, mapping errors, the share of opaque leaves, and rules covered by code against rules covered only by stamps, compared with SPACE's 23 bugs and 10 false positives over 30 apps.

Phase 3 plan, decided Oct 21, 2026:

- **GraphQL target.** GitLab, with a historical GraphQL authorization fix reproduced at the commit before it, as !132952 was for phase 1. GitLab at `7ce3a7d` runs graphql-ruby 1.13.19, so the tracer supports 1.x's `tracer` as well as 2.x's `trace_with`. Today every GitLab GraphQL decision lands on one entry point, `GraphqlController#execute`.
- **Revocation (threat 9), narrow.** A static lint and a test-mode collector, no generated temporal models: `research/models/revocation.als` stays a research model.
- **Shadow checking** runs in `hallmark watch`, a process outside the app that loads the mapping, not the app; nothing solves in the app's web or job workers, as the design rule requires.
- **Added to the roadmap row:** `c.restrict` (threat 11), list scopes (M5, and G5 with them), REST serializer fields (threat 4), and HMAC ids in production stamps (`docs/adr/0004`).
- **Hot path first.** The budget under "Runtime modes and performance budget" is a target, not a measurement; the benchmark comes before the modes so every later change is measured against it. Mapping readers (the app's own role queries) are measured and reported apart from Hallmark's own work.

Steps, in order; each updates this file and `CLAUDE.md` in the same change:

0. **Plan into the docs** (done Oct 21, 2026): this section, the roadmap row, `CLAUDE.md`'s phase 3 list, ADR 0004.
1. **Hot path and benchmark** (done Oct 21, 2026; "The shipped hot path"). `bench/hot_path.rb` and `rake bench` drive the collectors through Pundit, Action Policy and DeclarativePolicy on the test shop and through a booted Rails request, reporting p50 and p99 per decision and allocations, split into Hallmark's work and mapping readers. Baseline first. Expected changes: sampling decided once per request (in `Collectors.within_entry_point`) and per decision outside one, before any fact is read; a request-local memo of role reads (`Facts` reads roles in the current tenant and the record's tenant on every decision); fewer intermediate Hashes in `Facts#stamp`; a bounded event buffer that drops and counts when full; a cap on the store's seen set.
2. **Runtime modes, sinks and ids** (done Oct 21, 2026; "The shipped live modes"; routes are recorded when Rails loads them rather than in `after_initialize`, and examples are printed by `watch` in step 3). Modes `shadow` and `sampled` (`c.sample_rate`, `HALLMARK_SAMPLE`: 1.0 in test and shadow, 0.01 in sampled), on in any environment; routes recorded at boot in those modes. Sinks: the JSONL file as today, a Redis stream over the client the app passes (no new dependency), or any callable. The run named from `HALLMARK_RUN`, else the deploy revision, else the time. HMAC ids, off by default and never in test mode (`c.ids`, `c.id_key`, `HALLMARK_ID_KEY`), as a first-seen example beside a stamp, outside its key (ADR 0004).
3. **Baseline and `hallmark watch`** (done Oct 21, 2026; "The shipped watch"; inference runs again over all stamps on each batch rather than only the units new stamps touch, while checking stays incremental by exposure digest; the baseline also carries the run's stamp lines, which seed the watch). `hallmark check --baseline OUT` writes a verdict table (check, guard digest, verdict). `hallmark watch --baseline FILE` tails a sink, folds new stamps in, re-infers only the units they touch, re-checks only exposures whose guard changed on a warm sidecar, and reports counterexamples, drift and unchecked entry points not in the baseline (text, JSONL, SARIF; `c.on_finding` for alerts).
4. **Field-level mapping and `c.restrict`.** Fields as a dimension of read exposures (`field_policy RESOURCE, :field, <guard>`, intended access no wider than the record's read); `c.restrict` as sketched under "Ruby API sketch", each restriction ANDing a negation into the assertion of every exposure it covers. Storefront gains a field and a restriction, buggy and fixed.
5. **GraphQL, static.** `Extractor::GraphqlSchema` reads `app/graphql` (and `ee/app/graphql`) with Prism, never loading the app: types and their backing resources, fields and return types (lists, connections, resolvers, mutations), Node implementations, `loads:`, and the checks (`authorized?` through the method translator, GitLab's `authorize` through the DeclarativePolicy front end, Action Policy's `authorize:` and `preauthorize:`, `scope_items`). The model is `research/models/graphql.als` in the shipped catalog's terms: objects reachable from root fields and `node(id:)` through steps that pass each field's and child type's guards, one check per backed type and per field with a `field_policy`; witness paths through the sidecar's `eval`. Lints G4 and G5. `examples/graphql_shop` reproduces G1 to G3, and its fixed schema has no counterexample.
6. **GraphQL, runtime.** A tracer for 2.x (`trace_with`) and 1.x (`tracer`) naming field-path entry points (`Query.project.pipelineSchedules`) inside the controller's, recording `authorized?` outcomes and values replaced by nil; G6 when the mapping has a current tenant.
7. **List scopes (M5, G5).** `policy_scope`, `authorized_scope` and `scope_items` stamped as list decisions; Pundit `Scope#resolve` and Action Policy `relation_scope` bodies read as a guard over a record (`where(user: user)`, `where(organization: user.organizations)`, `all`), the rest through `term` or opaque (ADR 0003). A list exposure asserts its records are readable, and in the current tenant when the resource is mapped `lists: :current_tenant`.
8. **REST serializer fields (threat 4).** Grape::Entity (`expose ..., if:`, GitLab) and ActiveModel::Serializer (Mastodon) read with Prism; an entry point's serializer from `present ..., with:` or `render json: ..., serializer:`. Each exposed field with a `field_policy` becomes a field exposure. Jbuilder is a known limit.
9. **Revocation, narrow.** A lint for role reads behind `Rails.cache`, the session, token claims or a class-level memo with no clearing on the membership's commit; a test-mode collector that notes, in process memory only, a user whose roles in a tenant shrank and marks a later allow-stamp whose fresh facts lack a role an earlier allow had (`after_revocation`). Such stamps stay out of inference and are reported as stale access, failing the check. Candidate real bug: gitlab-org/gitlab!257244 and !258088 (an incident author downgraded who kept rights), or M3 if that turns out to be policy logic rather than a cache.
10. **Gate** (proposed; Anthony decides). Hot path: the budget met on the shop and on a real app's requests (Gumroad in development), at sample rates 1.0 and 0.01, with mapping-reader cost published beside it. Shadow: Gumroad at upstream `f3ef06a69`, where F9 (public since Oct 21, 2026) is still live, run in shadow mode with scripted traffic and `hallmark watch` against the test suite's baseline: F9 reported from live traffic, gone on the fix branch. GraphQL: a GitLab historical GraphQL fix found from code at the commit before it and gone at the fix, and the !132952 run's GraphQL stamps split into field paths. Fields and lists: at least one field-level or list-scope finding on a gate app, triaged. Every check under 10 s with no unknown; findings logs private, as before.

## Risks and open questions

The biggest risk is overclaiming: a bounded check that finds nothing is evidence, not proof, so every report must say "no counterexample within scope N" and list what was not modeled.

| Risk | Effect | Mitigation |
| --- | --- | --- |
| Guard extraction misses real logic | False negatives on custom policies | Opaque predicates are flagged, and runtime decisions must agree with the extracted guard |
| Catalog does not fit the app | Noise or silence on multi-tenant and attribute-based rules | Add a tenant-isolation pattern early; let users declare restrictions (threat 11) |
| Runtime only sees exercised paths | Untested actions go unchecked | Static extraction and route enumeration come before runtime collection |
| JVM required in CI or ops | Adoption friction for Ruby teams | Sidecar is a dev and CI dependency first; native-image later removes the JRE |
| Temporal checks grow fast | Slow or timed-out revocation checks | Keep traces short (6 to 10 steps) and scope small |
| SPACE's numbers come from 2016-era apps | Bug yield may differ on modern Rails code | Re-run on a modern app set in phase 2 and publish the comparison |
| Current org resolved in many places | Subdomain, path, header and jobs disagree; cross-tenant bugs slip between them | Collectors record which source set the org; jobs must carry it explicitly; scope always includes 2 or more orgs |
| GraphQL query shapes are unbounded | Runtime coverage of nested paths is thin; trace volume is high | Reachability comes from the static schema graph, bounded by Alloy scope; runtime events are deduplicated by field path |

Open questions:

- [ ] Reserve hallmark on RubyGems: a lookup on Oct 14 returned not found; confirm with gem search -e hallmark and push a placeholder release. Hallmark Cards dominates web search, so docs and the repo should say "Hallmark for Ruby".
- [x] Which adapter is first-class? Decided Oct 19, 2026: DeclarativePolicy. Action Policy is cheaper (instrumentation is built in) and Pundit has more installs, but DeclarativePolicy translates most exactly, so it may be the best first target for the static extractor.
- [x] Include graphql-ruby field authorization in v1? Decided Oct 14: yes, see the GraphQL section.
- [x] Phase 1 target apps, one per library. Pundit: decided Oct 15, Forem (Pundit plus Rolify), with HCB, Mastodon and rubygems.org as alternates; the Gumroad differential runs as a test, not a gate app. DeclarativePolicy: a slice of GitLab. Action Policy: decided Oct 15, Gumroad with its Pundit policies ported to Action Policy (no open-source app uses Action Policy; Gumroad has no Pundit scope classes, has 56 policy specs, is MIT licensed, and its per-seller team roles exercise the tenant-aware checks; running Hallmark on both versions cross-checks the two adapters). Mastodon is the fallback. Details in `CLAUDE.md`.
- [x] License: Apache-2.0 to match Alloy, or MIT? Decided Oct 19, 2026: Apache-2.0 (`LICENSE`, and `spec.license` in the gemspec).
- [x] Does a confirmed authorization flaw with no security impact (an over-broad rule whose only unscoped caller exposes nothing) count as the gate's "confirmed real bug"? Decided Oct 19, 2026: yes. The first Gumroad run found one (private findings log), and it is the Action Policy gate's bug. It is not reported to Gumroad (decided Oct 19, 2026): nothing leaks, since the page it redirects to denies.
- [x] Ruby floor (Oct 17, 2026): the gemspec asks for Ruby 3.2, but `lib/` loads and collects on 3.1.4 (GitLab at the gate commit runs 3.1, so Hallmark loaded through a local initializer instead of Bundler). Lower `required_ruby_version` to 3.1, or keep 3.2 and document the workaround? Decided Oct 19, 2026: keep 3.2. Ruby 3.1 is unsupported; the GitLab run's local initializer (`HALLMARK_LIB`, in `CLAUDE.md`, "GitLab slice") is the workaround.
- [x] Does Forem's live finding count as its gate bug? Decided Oct 18, 2026: yes. It is confirmed by a probe spec at `b042765` and is a flaw by the catalog, though Forem documents no intent either way; see the private log.
- [x] Report Forem's finding through dev.to/security: when, and by whom? Anthony emailed it to security@dev.to on Oct 19, 2026. Nothing about it is published until Forem fixes it or the policy's deadline passes.
- [x] Policy specs that call rules directly: built Oct 18, 2026 (the Pundit collector wraps each policy class's rules; "The shipped collectors").
- [ ] Does any target app need JRuby, or can the JRuby backend wait until after phase 4?
- [ ] Global abilities and headless policies (Oct 17, 2026, design note; not built): they are stamped class-level and not modeled. They usually gate platform staff (GitLab's `GlobalPolicy`, an admin dashboard), so they could later map to the catalog's platform-staff and administrator patterns through a named pseudo-resource (say `resource :global`) with no tenant, owner or record facts.
- [x] Abilities checked on a container: built Oct 19, 2026 as record flags, `public_when:` and conditional grants ("The shipped DeclarativePolicy front end"). The note as written Oct 17, 2026: GitLab checks `read_pipeline_schedule` against the `Project` on the schedules page and the list API, and the project's publicity (`public?`) is wider than its schedules' (`public? && public_builds?`), so mapped as a read of `Project` those checks show no finding. The mapping needs a way to say that an ability on a container guards the contained records, with their facts read from the container; for example a per-rule `resource:` that also applies to stamps, with the contained resource's `public_if:` taking the container.
- [x] Grape entry points: built Oct 19, 2026 (`Collectors::GrapeHook`, `Extractor::GrapeEndpoints`). The note as written Oct 17, 2026: the controller collector is a Rails `around_action`, so GitLab's REST API (Grape) stamps rules with no entry point, and `hallmark check` builds no exposure for them; only the matchers check those rules. Seen on the GitLab run: the API spec's leaking allows surfaced only through the rule's other entry point (GraphQL).
- [ ] SARIF or GitLab's format (Oct 19, 2026): GitLab's security dashboard reads its own SAST report (`gl-sast-report.json`), not SARIF. Should step 5 also write that?
- [ ] Creating a record (Oct 18, 2026, catalog gap, from the Forem run): the catalog has no pattern for creating a record, so an intended "any signed-in user may create an organization" reports a counterexample. Not planned for phase 2. Since Oct 21, 2026, `public_action "OrganizationPolicy", :create?, audience: :signed_in` declares exactly that intent (the public actions pattern); not rerun on Forem.
- [x] Phase 3 scope (Oct 21, 2026): which app proves GraphQL, how much of revocation, where shadow mode checks, and whether `c.restrict`, list scopes, serializer fields and HMAC ids join the phase. Decided Oct 21, 2026: GitLab with a historical GraphQL fix; revocation narrow (lint and test-mode collector); a `hallmark watch` process; all four join ("Phase 3 plan").
- [ ] Tenancy style: v1 assumes shared tables with an org foreign key. Does any target app use schema-per-tenant (Apartment-style), which hides the org from the data layer?

## Sources

- [Near and Jackson, Finding Security Bugs in Web Applications using a Catalog of Access Control Patterns (ICSE 2016)](https://groups.csail.mit.edu/sdg/pubs/2016/access-control-patterns-icse2016.pdf)
- [SPACE project page and preliminary code](https://www.uvm.edu/~jnear/space/)
- [Rubicon: Bounded Verification of Web Applications (DSpace@MIT)](https://dspace.mit.edu/handle/1721.1/86919)
- [Alloy 6.2.0 release announcement](https://alloytools.discourse.group/t/alloy-6-2-0-released/508)
- [Alloy on Maven Central and Homebrew](https://alloytools.discourse.group/t/alloy-available-on-maven-central-and-homebrew/525)
- [org.alloytools.alloy.application 6.2.0 on Maven Central (Apache-2.0)](https://central.sonatype.com/artifact/org.alloytools/org.alloytools.alloy.application)
- [Alloy downloads and API notes](https://alloytools.org/download.html)
- [Alloy API example: ExampleUsingTheCompiler.java](https://alloytools.org/documentation/code/ExampleUsingTheCompiler.java.html)
- [JRuby 10.0.0.0 release notes](https://www.jruby.org/2025/04/14/jruby-10-0-0-0)
- [jruby-rack 1.2.7: JRuby 10 and Rails 8.0 compatibility](https://github.com/jruby/jruby-rack/releases/tag/jruby-rack-1.2.7)
- [Action Policy instrumentation guide](https://actionpolicy.evilmartians.io/guide/instrumentation)
- [Schaad and Moffett, RBAC with separation of duty in Alloy](https://wiki.orbit-lab.org/raw-attachment/wiki/Internal/Rbac/RbacResources/p13-schaad.pdf)
- [graphql-ruby: Authorization](https://graphql-ruby.org/authorization/authorization.html)
- [graphql-ruby: Scoping](https://graphql-ruby.org/authorization/scoping.html)
- [graphql-ruby: Mutation authorization](https://graphql-ruby.org/mutations/mutation_authorization.html)
- [graphql-ruby: Tracing](https://graphql-ruby.org/queries/tracing.html)
- [Action Policy: GraphQL integration](https://actionpolicy.evilmartians.io/guide/graphql)
- [Rolify README](https://github.com/RolifyCommunity/rolify)
- [GitLab docs: The DeclarativePolicy framework](https://docs.gitlab.com/development/policies/)
- [declarative\_policy gem documentation](https://www.rubydoc.info/gems/declarative_policy)
