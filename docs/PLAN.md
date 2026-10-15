# Hallmark: Alloy-backed RBAC analysis for Ruby

Oct 14, 2026 · Anthony Byram

Exported from the planning doc on Oct 15, 2026, after phase 0 shipped. Keep this file current as the design changes; `CLAUDE.md` summarizes what is built versus planned.

## Summary

Hallmark is a Ruby gem that turns an app's role-based authorization (roles, grants, ownership rules, and the decisions it actually makes at run time) into an Alloy 6 model, then asks the Alloy Analyzer for counterexamples: a concrete user, role and record where an action is allowed that no intended access pattern allows.

The recommended direction:

- **Build on SPACE, change the fact source.** Near and Jackson's SPACE (ICSE 2016) already proved the idea: a small catalog of access control patterns in Alloy found 23 real bugs in Rails apps. Hallmark keeps the catalog and swaps fragile symbolic execution for policy-code extraction plus runtime observation.
- **Alloy 6.2 in a JVM sidecar.** The gem manages a long-lived Java process speaking JSON over stdio, so it works on CRuby. An in-process JRuby 10 backend comes later behind the same interface.
- **Never solve on the request path.** Requests only append cheap authorization events; verification runs in CI, in a staging shadow mode, or in a sampled background worker.
- **First target:** Rails 8.x with Pundit, Action Policy or DeclarativePolicy, with roles from Rolify, an enum column, or per-organization memberships, where one user can hold different roles in several orgs. graphql-ruby schemas, including field-level authorization, are in v1 too.

**Name:** Hallmark. A hallmark is the stamp that certifies what an alloy is made of, as this tool certifies an access policy. "Assay" (already a RubyGems assertion library) and "Warden" (the Rack auth gem Devise sits on) were ruled out.

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
| 13 | Cross-organization access | A role, ownership or invite from one org works on another org's records; six variants (M1 to M6) under Memberships | Runtime + policy code |
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

SPACE's evaluation also sets expectations for bounds: a scope of 3 was enough for every bug it found, and scope 8 still verified in under 10 seconds. Its own limits list is Hallmark's design brief: it assumes production behaves like analysis time, only sees ActiveRecord-to-view flows, and can miss bugs outside the bound.

## Embedding Alloy in Ruby

Use a gem-managed JVM sidecar by default and add an in-process JRuby backend second; both sit behind one `Hallmark::Solver` interface. Alloy 6.2.0 is the current release, Apache-2.0 licensed, and published to Maven Central as separate core, API, CLI and Pardinus (solver) artifacts, so it can be pinned like any dependency. Its documented Java entry points are `CompUtil.parseEverything_fromString` and `TranslateAlloyToKodkod.execute_command`.

| Option | How it works | Strengths | Weaknesses | Verdict |
| --- | --- | --- | --- | --- |
| A. JVM sidecar | Small Java shim (`hallmark-solver.jar`) wrapping the Alloy API; JSON-RPC over stdio; spawned and supervised by the gem | Works on any CRuby; solver memory and timeouts cannot take down Puma; warm JVM amortizes startup | Needs a JRE 17+ where analysis runs; serialization cost | **Default** |
| B. In-process on JRuby 10 | `require` the Maven jars and call the Java API directly | No IPC; direct access to AST and instances | JRuby 10 tracks Ruby 3.4 and needs Java 21; most Rails shops run CRuby | **Second backend** |
| C. Shell out to the 6.2 CLI | Write `.als`, run `alloy exec --type xml`, read verdicts from `receipt.json` and witnesses from the XML instances | Zero Java code | Cold JVM per run (about 2 s for six checks); coarse control | **Phase 0 backend (built)** |
| D. GraalVM native-image of the shim | Compile option A to a native binary | No JRE to install; fast start | Reflection config, native SAT solver libraries | **Later optimization** |
| E. Rjb or JNI inside CRuby | Load a JVM into the Ruby process | No sidecar | Unsafe with forking servers and preload; crashes take the app down | Rejected |
| F. Swap Alloy for SMT | Encode to Z3 or cvc5 instead | Unbounded proofs | Not Alloy; SPACE notes its quantifier alternation makes the check undecidable, which favours a bounded model finder | Out of scope |

Solver choices inside the shim: SAT4J (pure Java) as the default for portability, native MiniSat or Glucose from the dist jar as an opt-in for speed. Alloy 6 temporal checks run as bounded traces on the SAT backend; unbounded temporal checking needs NuSMV or nuXmv on the PATH, so v1 avoids it.

The shim protocol stays tiny: `load(model_text) -> model_id`, `check(model_id, command, scope, timeout_ms) -> {sat, instance}`, `eval(model_id, instance_id, expr)`. Instances come back as JSON atoms and tuples, which the Ruby side maps back to app classes and record ids.

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
  Fact store: events deduped into signatures, plus a role-config snapshot
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

**1. The shipped catalog** (`catalog.als`), SPACE's patterns plus structural RBAC checks:

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
| `NoHierarchyCycles` on a sample Rolify config | Holds | None |
| `StaticSoD` on the same config | Counterexample | One user assigned both `Requester` and `Approver`; nothing forbids it |
| `NoEscalationByAssignment` | Counterexample | A `Support` user can assign `Editor`, a role they do not hold |

The CLI writes a `receipt.json` per run plus one XML instance per counterexample. Phase 0 found that the receipt's own `values` map keys atoms by their parent signature and silently drops some, so verdicts come from `receipt.json` and witnesses (skolems and field tuples) from the A4 XML. The sidecar should return witnesses in a shape the same decoder can read.

## Memberships and multiple organizations

When a user can belong to several organizations, a role is a fact about a (user, organization) pair, so every check must answer "in which org?". Hallmark makes tenancy a dimension of the whole catalog rather than one more pattern; on Oct 14, 2026 the model below found all six cross-org flaws listed here and confirmed the fixed guard.

What changes in the model:

- **Membership replaces global assignment.** `Membership(user, org, roles)`, at most one per user and org; a user's roles in org A say nothing about org B.
- **Every record has a tenant.** Ownership, grants and admin rights are evaluated inside the record's org, so creating a record no longer grants access after the creator leaves that org.
- **The request carries a current org** (subdomain, path segment, session, header or `Current.organization`), modeled as `cur`. Guards are checked for every pairing of `cur` and the record's org, which is where most real cross-tenant bugs live.
- **Rolify grants outside an instance are modeled explicitly.** A global role, or one scoped to the `Organization` class, satisfies the instance-scoped check for every org unless Rolify's strict mode or `has_strict_role?` is used.
- **Intended cross-org access is declared, not guessed.** Platform staff roles (support, billing) are listed in the mapping so they are not reported.

| # | Flaw | Guard Hallmark extracted (example) | Witness Alloy returned |
| --- | --- | --- | --- |
| M1 | Unscoped role check | `current_user.memberships.exists?(role: :admin)` | An admin of one org destroys a project in another org |
| M2 | Current-org confusion | Admin of `Current.organization`; record loaded with `Project.find(params[:id])` | An admin of the current org edits a project belonging to a different org |
| M3 | Ownership outlives membership | `record.creator == user` | A user with no remaining membership still edits a project they created |
| M4 | Cross-org invitation | Admin of the current org; target org read from `params[:organization_id]` | An admin of one org creates an invite into an org where they hold no admin role |
| M5 | List scope spans all orgs | `policy_scope` returns projects from every org the user belongs to | While viewing org 2, the list includes org 1's projects (may be an intended dashboard, so Hallmark asks) |
| M6 | Rolify grant at the wrong scope | `has_role?(:admin, org)` with a global or class-level grant present | Admin rights in an org the user is not a member of |

The core of `tenancy.als`, with M2 and its fix:

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

**Scope rule:** the last line is the lesson. With one org in scope, the M2 bug cannot be represented and the check passes. Hallmark therefore never lets `Org` drop below 2, and every generated model includes a user with memberships in two orgs.

**Mapping additions:**

```ruby
c.map do
  principal User
  tenant Organization, membership: Membership, member: :user, roles: :role  # or rolify: true
  current_tenant -> { Current.organization }   # or ActsAsTenant.current_tenant
  platform_role :support                        # cross-org access that is intended
  resource Project, tenant: :organization, owner: :creator
end
```

**New runtime facts per event**, all booleans or role names: which source set the current org, whether the record is in the current org, whether the user is a member of the record's org, and the user's role set in both orgs. The static extractor also flags role checks that take no org argument, and tenant-owned models that skip the app's tenant scoping (for example a model with an `organization_id` column but no `acts_as_tenant`).

**Where the current org comes from:** Action Policy can pass extra authorization context (such as the current account) into every policy, so its collector gets `cur` for free. Pundit apps usually wrap user and org in a context object, which the mapping names. Background jobs have no request, so the collector flags jobs that load tenant-owned records without an org argument.

## GraphQL field authorization (v1)

v1 treats a graphql-ruby schema as a second set of entry points: every root field, `node(id:)` lookup and mutation is an exposure, and every object reached through nested fields is held to the same catalog and membership rules as a controller action. On Oct 14, 2026 the model below found three schema-level bugs and verified the fixed schema.

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

Hallmark v1 ships a third adapter for the `declarative_policy` gem (MIT licensed), the framework GitLab built and uses for its authorization. Its rules are already declarative, so translation is more exact than for Pundit or Action Policy: each `rule { ... }.enable` or `.prevent` line becomes one Alloy formula, and only condition bodies remain ordinary Ruby. On Oct 14, 2026 the model below found three DeclarativePolicy-specific flaws and confirmed the fixed rule.

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
  c.solver  = :sidecar            # or :jruby, :cli (spike only)
  c.scope   = 5                   # SPACE found every bug at 3; 8 stayed under 10 s
  c.timeout = 10_000              # ms per check

  c.map do
    principal User, roles: ->(u) { u.roles.pluck(:name) }   # Rolify
    resource  Post,    owner: :author, public_if: :published?
    resource  Profile, owner: :user,   kind: :profile
    resource  Share,   permits: { user: :grantee, target: :document, op: :level }
    role_hierarchy admin: %i[editor approver], editor: %i[author]
    conflicts [:requester, :approver]
  end

  # Threat 11: stricter than the catalog's admin pattern
  c.restrict "admins never read card data" do
    deny role: :admin, op: :read, resource: PaymentMethod, fields: %i[number cvc]
  end
end
```

**Collectors**, one adapter per authorization library:

- **Action Policy:** subscribe to its built-in `action_policy.authorize` and `action_policy.apply_rule` notifications, which already carry policy class, rule and result.
- **Pundit:** no instrumentation exists, so `prepend` a module on `Pundit::Authorization#authorize` and on `policy_scope`.
- **No library:** a controller `around_action` records which actions finished without any authorization call (threat 10).
- **Data side:** ActiveRecord `find` and `update` notifications tie a request to the record type and the mapped ownership fact (`record.owner == current_user`, recorded as a boolean, never the ids).
- **graphql-ruby:** a `trace_with` module records each resolved field path, its `authorized?` outcome and any value replaced by `nil` (details under GraphQL).
- **DeclarativePolicy:** no instrumentation exists, so `prepend` a module on `DeclarativePolicy::Base#allowed?` (details under DeclarativePolicy).

**Static extractor:** Prism parses policy methods and translates a supported subset into Alloy guards: `user.present?`, `user.has_role?(:x)`, `user.admin?`, `record.user == user`, `record.user_id == user.id`, `record.published?`, `&&`, `||`, `!`. Anything outside the subset becomes an opaque predicate, and runtime decisions must agree with the extracted guard; a disagreement is reported as drift.

**Where results show up:**

```ruby
# RSpec
RSpec.describe PostPolicy do
  it { is_expected.to satisfy_catalog }                 # every rule maps to a pattern
  it { is_expected.to have_no_counterexample(:update?) }
end
```

```bash
bin/hallmark check            # static + recorded traces, exit 1 on any counterexample
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

Budget and mechanics (targets to confirm in phase 3, not measurements):

- **Hot path:** one struct appended to a per-thread ring buffer, aiming for under 20 µs p99 and zero allocations beyond the event; a flusher thread writes JSONL or a Redis stream.
- **Deduplication:** events collapse to a signature of controller action, policy rule, decision, role set and mapped facts (owner? public? granted?). Only a new signature, a new deploy or a changed role config triggers a re-check.
- **Solver limits:** sidecar heap capped (default 512 MB), per-check timeout, one solver thread per core. A timeout is reported as "unknown", never as "safe".
- **Privacy:** events hold class names, rule names, role names and booleans; record and user ids are HMAC-hashed with a per-environment key so witnesses can be traced by an operator without storing raw ids.

## Roadmap

The spike is deliberately small: shell out to the 6.2 CLI, hand-write the generated `.als` for one demo app, and prove the loop end to end before building the sidecar.

A working spike in two weeks, a usable gem by week 6. Weeks are estimates for one engineer.

| Phase | Weeks | Delivers | Exit gate | Status |
| --- | --- | --- | --- | --- |
| 0. Spike | 1 to 2 | CLI backend, `catalog.als`, one demo app | MediumClone bugs reproduced | Done Oct 15, 2026 |
| 1. Core gem | 3 to 6 | Sidecar shim, tenant-aware DSL, collectors, RSpec matchers | 2 Rails 8 apps, each check under 10 s | Next |
| 2. Extractor | 7 to 10 | Prism guards, drift reports, SARIF, GraphQL schema walk | Bug yield compared with SPACE | |
| 3. Runtime | 11 to 14 | Shadow and sampled modes, GraphQL tracing, revocation checks | Hot-path budget met in benchmark | |
| 4. Hardening | 15 on | JRuby backend, native-image, field-level rules, CI integrations | | |

Phase 0 shipped as the gem skeleton: catalog, mapping and guard DSL with grants, model builder, CLI backend, witness decoder, and the MediumClone example with its fix. Phase 2's gate is the honest test of the whole idea: if extraction plus runtime facts finds fewer real bugs than SPACE did on comparable apps, revisit the extraction approach before investing in runtime modes.

## Risks and open questions

The biggest risk is overclaiming: a bounded check that finds nothing is evidence, not proof, so every report must say "no counterexample within scope N" and list what was not modeled.

| Risk | Effect | Mitigation |
| --- | --- | --- |
| Guard extraction misses real logic | False negatives on custom policies | Opaque predicates are flagged, and runtime decisions must agree with the extracted guard |
| Catalog does not fit the app | Noise or silence on multi-tenant and attribute-based rules | Add a tenant-isolation pattern early; let users declare restrictions (threat 11) |
| Runtime only sees exercised paths | Untested actions go unchecked | Static extraction and route enumeration come before runtime collection |
| JVM required in CI or ops | Adoption friction for Ruby teams | Sidecar is a dev and CI dependency first; native-image later removes the JRE |
| Temporal checks grow fast | Slow or timed-out revocation checks | Keep traces short (6 to 10 steps) and scope small |
| SPACE's numbers come from 2016-era apps | Bug yield may differ on Rails 8 code | Re-run on a modern app set in phase 2 and publish the comparison |
| Current org resolved in many places | Subdomain, path, header and jobs disagree; cross-tenant bugs slip between them | Collectors record which source set the org; jobs must carry it explicitly; scope always includes 2 or more orgs |
| GraphQL query shapes are unbounded | Runtime coverage of nested paths is thin; trace volume is high | Reachability comes from the static schema graph, bounded by Alloy scope; runtime events are deduplicated by field path |

Open questions:

- [ ] Reserve hallmark on RubyGems: a lookup on Oct 14 returned not found; confirm with gem search -e hallmark and push a placeholder release. Hallmark Cards dominates web search, so docs and the repo should say "Hallmark for Ruby".
- [ ] Action Policy or Pundit as the first-class adapter? Action Policy is cheaper (instrumentation is built in); Pundit has more installs. DeclarativePolicy is also in v1 and translates most exactly, so it may be the best first target for the static extractor.
- [x] Include graphql-ruby field authorization in v1? Decided Oct 14: yes, see the GraphQL section.
- [ ] License: Apache-2.0 to match Alloy, or MIT?
- [ ] Does any target app need JRuby, or can the JRuby backend wait until after phase 4?
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
