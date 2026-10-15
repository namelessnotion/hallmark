# Hallmark

Hallmark checks a Ruby app's role-based authorization against a catalog of
access control patterns written in Alloy 6, and reports every exposure that
no pattern allows, with a concrete counterexample. It builds on Near and
Jackson's SPACE (ICSE 2016).

- `docs/PLAN.md` is the design: threat catalog, architecture, the Alloy
  encodings for memberships, GraphQL and DeclarativePolicy, the roadmap and
  open questions. Read the relevant section before starting work on a phase.
- `README.md` is the user-facing description of what exists today.

## Status

Phase 0 (spike) is done. Phase 1 is next; see "Next work" below.

Built:
- `data/hallmark/catalog.als`: SPACE's patterns (ownership, public objects,
  authentication, explicit permission, user profiles, administrators) plus
  structural role checks
- Mapping and guard DSL with `grant`; model builder; Alloy 6.2 command-line
  backend; witness decoder; text report; `bin/hallmark` CLI; jar installer
- `examples/medium_clone`: reproduces both bugs from the SPACE paper's
  Figure 2, and the fixed version verifies (the phase 0 exit gate)

Not built yet, but designed and validated as hand-written models in
`research/models` (see its README for each check's expected result):
memberships across organizations, graphql-ruby, DeclarativePolicy, stale
access after revocation, role-configuration checks.

The spike's DSL uses class names as strings and hand-written guards. The
`Hallmark.configure` / `c.map` sketch in `docs/PLAN.md` ("Ruby API sketch") is
the target design, not current behavior.

## Commands

```bash
bundle install
bin/hallmark install-alloy                 # Alloy 6.2.0 to ~/.cache/hallmark, SHA-256 verified; needs Java 17+
bundle exec rake test                      # 25 tests; the 5 integration tests skip without the jar
bin/hallmark check examples/medium_clone/hallmark.rb    # exits 1 (two counterexamples, expected)
bin/hallmark check examples/medium_clone/hallmark_fixed.rb
bin/hallmark model FILE                    # print the generated Alloy model; the fastest way to debug
bundle exec rake fixtures:regenerate       # refresh test/fixtures/medium_clone from a real run
java -jar ~/.cache/hallmark/alloy-6.2.0.jar exec -c '*' research/models/tenancy.als
```

Run `rake fixtures:regenerate` after changing `catalog.als`, the model
builder's output, or `examples/medium_clone/hallmark.rb`, then rerun the tests:
`test/report_test.rb` asserts specific witness atoms (such as `User$1`) that
can shift when the model changes. Solver output is deterministic for a given
model; a regeneration with no model change only touches the receipt's
timestamp, so revert that.

Settings come from the environment (`HALLMARK_ALLOY_JAR`, `HALLMARK_JAVA`,
`HALLMARK_SCOPE`, `HALLMARK_TIMEOUT`, `HALLMARK_SOLVER`) or `Hallmark.configure`.
`HALLMARK_SOLVER=minisat` or `glucose` uses the native solvers bundled in the
jar (including darwin/arm64); the default is SAT4J, pure Java.

## How the code fits together

```text
Hallmark.analyze block
  -> Analysis (Mapping + Exposures, each with a Guard)       lib/hallmark/analysis.rb, mapping.rb, guard.rb
  -> ModelBuilder: Alloy source, one assert + check per exposure   model_builder.rb
  -> Solver::CLI#check: `java -jar alloy.jar exec --type xml`      solver/cli.rb
  -> Receipt: verdicts from receipt.json, witnesses from XML       receipt.rb
  -> Report and Finding: witness explained in app terms            report.rb, finding.rb
```

Every exposure becomes:

```alloy
pred allows_<Action>_<op>[p: Principal, r: <Sig>] { <guard> }
assert safe_<Action>_<op> { all p: Principal, r: <Sig> | allows_...[p, r] implies allowed[p, <Op>, r] }
check safe_<Action>_<op> for <scope>
```

`Finding` reads the witness from the skolems `$safe_<Action>_<op>_p` and
`_r`, so keep the quantified variables named `p` and `r`.

## Alloy facts learned building phase 0

- `receipt.json`'s `values` map is lossy: it keys atoms by their parent
  signature and silently drops some. Use it only for verdicts. Witnesses come
  from `<command>-solution-0.xml` (the A4 XML format).
- A check that holds has no `solution` key in `receipt.json`.
- Atoms from an opened module carry its name (`catalog/User$0`); atoms of
  signatures in the main model do not (`Post$0`). `Naming.atom` strips it.
- Two commands with the same name collide in `receipt.json` (the last wins).
  `Analysis` rejects duplicate action and op pairs for this reason.
- `exec --force` deletes and recreates the output directory. Never point it at
  a directory holding anything else.
- Syntax errors exit 1 with the message on stderr. The JVM may print
  "Picked up JAVA_TOOL_OPTIONS" first; `Solver::CLI` filters it.
- Alloy has no boolean literals. The catalog defines `pred unguarded {}` as
  "true". Alloy 6 reserves temporal keywords (`always`, `eventually`, `after`,
  `before`, `once`, `since`, `until`, `steps`, `var` and others), so never
  generate identifiers with those names.
- Anything a fact does not pin down, the solver chooses adversarially. Every
  mapping option must become a fact (ownership, publicity, grants); otherwise
  checks report spurious counterexamples. `grant` exists because without it a
  role-guarded action could never pass.
- Scope must be 2 or more. Tenancy checks need at least 2 `Org` atoms: the
  current-org confusion bug (M2 in the plan) is invisible with 1.
- The jar targets Java 17 (class file version 61). Bump `ALLOY_VERSION` and
  `AlloyInstaller::SHA256` together.
- The Java API lives in `edu.mit.csail.sdg.parser.CompUtil`,
  `edu.mit.csail.sdg.translator.{TranslateAlloyToKodkod, A4Options, A4Solution}`
  and `edu.mit.csail.sdg.alloy4.A4Reporter` (the old `alloy4compiler` packages
  are gone). Maven Central publishes Alloy 6.2.0 under `org.alloytools`.
- A CLI run of the six MediumClone checks takes about 2 s, almost all JVM
  start. That is the cost the phase 1 sidecar removes.

## Conventions

- Ruby 3.2+ (endless methods, anonymous block forwarding are fine);
  `# frozen_string_literal: true` everywhere; the test task runs with warnings
  on and should stay warning-free.
- No runtime dependencies beyond `rexml`. No network access at runtime except
  `hallmark install-alloy`. Never vendor the Alloy jar.
- Design rule: never run the solver on a request path. Requests only append
  events.
- Report wording: a passing check means "no counterexample within scope N",
  never "safe" or "verified".
- Unit tests must run without Java (decode fixtures). Tests that need the jar
  call `require_solver!`, which skips when it is missing.
- Prose in docs, comments and commit messages: no em dashes; use commas,
  semicolons or parentheses.
- When a design decision changes, update `docs/PLAN.md` (roadmap status and
  open questions included) in the same change.
- `.gitlab-ci.yml` (ruby:3.4-bookworm plus openjdk-17) has not run yet; check
  the first pipeline.

## Next work: phase 1 (core gem)

Exit gate: Hallmark runs on three apps, one per authorization library
(Pundit, Action Policy, DeclarativePolicy), with each check under 10 seconds.
Any Rails version is fine; Rails 8 is not required.

### Target apps

Checked Oct 15, 2026 against each app's Gemfile on its default branch:

| Library | Candidate | Why | Notes |
| --- | --- | --- | --- |
| Pundit | [Forem](https://github.com/forem/forem) | Pundit plus Rolify, Rails 8.0; exercises role mapping | Large codebase; start with one area (articles, comments) |
| Pundit (alternates) | [HCB](https://github.com/hackclub/hcb) (Rails 8.1), [Mastodon](https://github.com/mastodon/mastodon) (Rails 8.1), [rubygems.org](https://github.com/rubygems/rubygems.org) (Rails 8.1) | All list `pundit` in their Gemfiles | HCB's users belong to several organizations, which suits the tenant-aware DSL; confirm by reading its models |
| DeclarativePolicy | [GitLab](https://gitlab.com/gitlab-org/gitlab) | The only substantial public user; group and project memberships with inheritance | Huge; scope it to one slice, such as `ProjectPolicy` and `IssuePolicy` |
| Action Policy | [Gumroad](https://github.com/antiwork/gumroad) with its Pundit policies ported to Action Policy (decided Oct 15, 2026) | No open-source app uses Action Policy, and a port keeps real app logic | See "Porting Gumroad to Action Policy" below |

Before building the gate for a target, confirm the app still uses the library
(`grep` its Gemfile.lock and `app/policies`), and record the commit you test
against so results are reproducible.

Target apps live outside this repository, as separate checkouts or forks
pinned to a commit. Never copy their code into Hallmark: Forem, Mastodon and
HCB are AGPL-3.0, GitLab mixes MIT with its proprietary `ee/` directory, and
Hallmark's own license is not chosen yet. Short excerpts in docs, with a
link to the source, are fine.

### Porting Gumroad to Action Policy

Policy folders compared Oct 15, 2026 by sparse checkout of each default branch:

| App | Policy files | Lines | Pundit scope classes | Policy specs | License |
| --- | --- | --- | --- | --- | --- |
| Gumroad (`e184d51`) | 69 | 1,720 | 0 | 56 | MIT |
| Mastodon (`a4be641`) | 48 | 1,017 | 0 | 43 | AGPL-3.0 |
| Forem (`d8b2ba5`) | 40 | 1,565 | 3 | not counted | AGPL-3.0 |
| HCB (`7d0b932`) | 96 | 3,748 | 3 | not counted | AGPL-3.0 |
| rubygems.org (`a271c27`) | 61 | 1,401 | 59 | not counted | MIT |

Why Gumroad:
- **No scope classes.** Action Policy's migration guide says Pundit scope
  classes have no automatic path; Gumroad has none.
- **It exercises the tenant-aware work phase 1 builds.** Policies get a
  context with both `user` and `seller` (the account being acted for), and
  users hold per-seller roles: `role_owner_for?`, `role_admin_for?`,
  `role_marketing_for?`, `role_support_for?`, `role_accountant_for?`. One user
  can be a team member of several sellers. Some rules check that the record
  belongs to the current seller (`LinkPolicy#update?` returns false when
  `record.user != seller`) and others check only the role, which is the
  current-org confusion check (M2 in the plan) on real code.
- **56 policy specs** to prove the port kept behavior, and an MIT license.

Mastodon is the fallback: the smallest policy set and also scope-free, but
its read rules depend on visibility, follows, mentions and blocks, which the
catalog does not cover yet, so it would pull catalog work into phase 1.

Gumroad specifics seen in `app/policies/application_policy.rb`: the
constructor takes `(context, record)` and reads `context.user` and
`context.seller`; it raises `Pundit::NotAuthorizedError` when there is no user
unless the policy calls `allow_anonymous_user_access!`; and
`when_record_available` skips record checks when authorizing a class. In
Action Policy, `user` and `seller` become two authorization context entries
(`authorize :user` and `authorize :seller`), and the anonymous-access rule
can become a pre-check.

Steps, following the [official migration guide](https://actionpolicy.evilmartians.io/guide/pundit_migration):

1. Fork Gumroad (for example to `gitlab.com/namelessnotion/gumroad-action-policy`)
   at the commit you will test against; record it here.
2. Guide phase 1: replace `include Pundit` with Action Policy in the
   controllers, add the `authorize(record, rule = nil)` shim that forwards to
   `authorize!`, and add `policy` and `policy_scope` helpers. In
   `ApplicationPolicy`, include `ActionPolicy::Policy::Core`, declare the
   `user` and `seller` context, and replace the constructor.
3. Get Gumroad's existing policy specs passing by swapping
   `require "pundit/rspec"` for `require "action_policy/rspec/pundit_syntax"`
   and adapting how specs build the context. Passing specs are the evidence
   that the port kept behavior.
4. Guide phase 2: inherit from `ActionPolicy::Base`, replace raises of
   `Pundit::NotAuthorizedError`, and move view helpers to `allowed_to?` and
   `authorized`.
5. Differential check, a free test of the adapters: run Hallmark on the
   original Pundit Gumroad and on the port at the same commit. Findings must
   match; any difference is a bug in one of the two adapters.

Suggested order:

1. **Sidecar solver.** A small Java project (for example `solver/`) built
   against the `org.alloytools` 6.2.0 artifacts, speaking line-delimited
   JSON-RPC over stdio: `load(model_text)`, `check(model_id, command, scope,
   timeout_ms)`, `eval(...)`. It returns the verdict plus skolems and field
   tuples in a shape `Receipt::Instance` can read. On the Ruby side, add
   `Hallmark::Solver::Sidecar` with the same `check(model)` interface as
   `Solver::CLI`. It spawns and supervises the process, caps the heap,
   restarts it after a timeout or crash, and reports a timeout as "unknown".
   Keep `Solver::CLI` as the fallback and as a cross-check in tests.
2. **Tenant-aware catalog and DSL.** Port `research/models/tenancy.als` into
   the shipped catalog: memberships, a tenant on every record, the current
   org. Add `tenant`, `current_tenant` and `platform_role` to the mapping, and
   enforce at least 2 orgs in scope.
3. **Collectors and Railtie.** Action Policy (subscribe to
   `action_policy.authorize`), Pundit and DeclarativePolicy (prepend modules),
   and an `around_action` that flags actions finishing without any
   authorization call. Events are small structs flushed off the request
   thread.
4. **RSpec matchers:** `satisfy_catalog`, `have_no_counterexample(:rule?)`.

## Open questions (Anthony decides; do not choose)

- Final pick among the Pundit candidates (Forem is the working choice).
- License: Apache-2.0 (matches Alloy) or MIT. Until then the README says all
  rights are reserved; do not add a LICENSE file.
- First-class adapter: Action Policy, Pundit or DeclarativePolicy.
- Reserving the `hallmark` name on RubyGems.
- Whether any target app needs JRuby, and whether any uses schema-per-tenant.
