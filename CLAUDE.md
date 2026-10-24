# Hallmark

Hallmark checks a Ruby app's role-based authorization against a catalog of
access control patterns written in Alloy 6, and reports every exposure that
no pattern allows, with a concrete counterexample. It builds on Near and
Jackson's SPACE (ICSE 2016).

- `docs/PLAN.md` is the design: threat catalog, architecture, the Alloy
  encodings for memberships, GraphQL and DeclarativePolicy, the roadmap and
  open questions. Read the relevant section before starting work on a phase.
- `README.md` is the user-facing description of what exists today.
- `CONTEXT.md` is the glossary (tenant, entry point, rule, stamp, assay,
  hallmark and the rest); use its terms and avoid the ones it lists.
- `docs/adr/` records hard-to-reverse decisions and why.

## Status

Phase 0 (spike) is done. Phase 1's deliverables are built: step 1
(tenant-aware catalog and DSL), step 2 (collectors, stamp store, Railtie),
step 3 (solver sidecar) and step 4 (RSpec matchers). Its exit gate, Hallmark
on three real apps, passed on Oct 19, 2026, so phase 1 is done. Phase 2 (the
extractor) started Oct 19, 2026, and its step 1 (Pundit and Action Policy
rules read from code), step 2 (drift) and step 3 (controllers and routes) were done the same day, steps 4
(DeclarativePolicy, Grape) and 5 (SARIF) too, and its gate (step 6) ran Oct 19
to 21, 2026 on five apps and passed (decided Oct 21, 2026), so phase 2 is
done and phase 3 (runtime modes and GraphQL) is next, planned Oct 21, 2026
("Phase 3 (runtime and GraphQL)" below, `docs/PLAN.md` "Phase 3 plan"); phase
2's plan is "Phase 2 (extractor)" below and `docs/PLAN.md` ("Roadmap", "Phase 2 plan"). The gate's
two false-positive sources (op errors, two catalog gaps) were fixed Oct 21,
2026 (Phase 2 step 7 below). Phase 3 steps 1 (hot path and benchmark),
2 (live modes, sinks, hashed ids), 3 (baseline and `hallmark watch`),
4 (field policies and restrictions), 6 (GraphQL runtime tracing, ahead
of step 5) and 5 (GraphQL schema walk) were done Oct 21, 2026, steps 7 (list scopes)
and 8 (REST serializer fields) on Oct 22, 2026, and step 9 (revocation, narrow) on
Oct 24, 2026. The phase 1 gate's record is in
"Phase 1 (core gem): the gate" below. The first real-app run (original Gumroad on Pundit, Oct 16, 2026, not
a gate app) is in "First run on original Gumroad" below. Gate runs so far:
GitLab (DeclarativePolicy, Oct 17, 2026) and Forem (Pundit, Oct 18, 2026),
both meeting the gate's criteria, in "GitLab slice" and "Forem slice" below;
and Action Policy (the Gumroad port, Oct 19, 2026), whose real bug is F6, a
flaw with no security impact found, which Anthony counted for the gate (Oct
19, 2026), in "Gumroad Action Policy port" below. That run found the controller hook running after
controllers' own `before_action`s (fixed Oct 19, 2026); GitLab and Forem,
rerun with the fix the same day, gave identical results and still meet the
gate.

Decided Oct 19, 2026: Hallmark is Apache-2.0 (`LICENSE`), and DeclarativePolicy
is the first-class adapter.

Built:

- `data/hallmark/catalog.als`: SPACE's patterns (ownership, public objects,
  authentication, explicit permission, user profiles, administrators),
  platform staff, ownership without membership and public actions (Oct 21,
  2026), and structural role checks. Tenancy is a dimension of
  every pattern: `Tenant`, `Membership`, a tenant on every record, roles
  counted in the record's tenant (`rolesFor`). The encoding is described in
  `docs/PLAN.md` ("The shipped encoding").
- Mapping and guard DSL with `grant`; model builder; Alloy 6.2 command-line
  backend; witness decoder; text report; `bin/hallmark` CLI; jar installer
- `examples/medium_clone`: reproduces both bugs from the SPACE paper's
  Figure 2, and the fixed version verifies (the phase 0 exit gate)
- Tenant-aware mapping: `tenant` (with `membership:`, `member:`, `roles:`
  and `self:`), `current_tenant`, `platform_role`, `resource ..., tenant:`
  (with `tenant_optional: true` when some records have none, as Forem's
  personal articles);
  class constants or strings (constants only where the app is loaded: the
  Railtie and the matchers; `bin/hallmark` stops with an error naming the
  class). Guards: `role(:x, tenant: :current | :record | :any)` and
  `in_current_tenant`.
- `examples/storefront`: a Gumroad-shaped store (the seller is a User,
  products have tenant :user and no owner) reproducing M2, current-tenant
  confusion; the fixed version verifies
- Collectors (`lib/hallmark/collectors/`): Action Policy (prepended
  `apply_r` plus the `action_policy.authorize` subscription), Pundit
  (prepended `authorize`, and a wrapper on each policy class's rules for direct calls in policy specs), DeclarativePolicy (prepended `allowed?`), and an
  `around_action` flagging unchecked entry points (threat 10). Each is loaded
  only when its library is. Facts are read through mapping readers
  (`principal from:/roles:`, `tenant roles_in:`, `current_tenant`).
- `StampStore` (queue plus flusher thread, JSONL in `tmp/hallmark/`),
  `StampSet`, `Inference` (guards from allow-stamps, entry point exposures,
  op convention, `rule ..., op:/guard:` overrides), `Coverage` (the "not
  observed" section) and a Railtie that, in the test environment, loads
  `config/hallmark.rb` in `after_initialize` (once Rails autoloads app
  classes; moved there Oct 16, 2026) and installs the collectors. With the
  collectors off it does not load the file. `docs/PLAN.md` ("The shipped
  collectors") has the details and known limits.
- `Hallmark.configure { |c| c.map { ... } }` holds the app's mapping; an
  analysis starts from it, and `hallmark check config/hallmark.rb` infers
  exposures from the recorded stamps.
- Solver sidecar (`solver/src/hallmark/solver/`, Java 17, plain `javac`
  against the Alloy dist jar; `Hallmark::Solver::Sidecar` plus
  `Solver::ChildProcess`): line-delimited JSON-RPC (`version`, `load`,
  `check`, `eval`, `unload`), witnesses as `{fields, skolems}` that
  `Receipt::Instance` reads directly. Opt-in with `c.solver = :sidecar` or
  `HALLMARK_SOLVER=sidecar`; the CLI stays the default and the cross-check.
  Timeouts, out-of-memory and crashes are unknown (`Report#unknown`), and the
  sidecar restarts for the next check; a failed restart or model load makes
  the rest of the run unknown and keeps the verdicts so far. `docs/PLAN.md` ("The shipped
  sidecar") has the protocol, choices and timings.
- RSpec matchers (`lib/hallmark/rspec.rb`, loaded by `require
  "hallmark/rspec"`): `satisfy_catalog` and `have_no_counterexample(:rule?)`,
  on `Hallmark::RuleCheck`, which checks each rule's guard as its own check
  named after the rule. The sidecar by default, the CLI when it is not built.
  The `:hallmark` tag sets the subject and runs tagged groups last.
  `examples/storefront/link_policy_spec.rb` runs both on the buggy and fixed
  Storefront. `docs/PLAN.md` ("The shipped matchers") has the choices.
- Extractor (phase 2 step 1, Oct 19, 2026; `lib/hallmark/extractor.rb` and
  `lib/hallmark/extractor/`): reads Pundit and Action Policy rules from
  `app/policies` under `c.root` with Prism, never loading them
  (`SourceIndex`), translates each into a guard (`MethodTranslator`) over
  terms from the mapping and its `term "source", guard` declarations
  (`Terms`). Calls it cannot read become `Guard` kind `:opaque`, which
  `to_alloy` refuses; `Guard#bounds` gives the lower and upper bounds, and a
  rule's checked guard is the lower bound OR its inferred guard
  (`docs/adr/0003`). `Inference`, `RuleCheck` and the matchers take the
  extractor (`Extractor.load(mapping, root)`, nil without `app/policies` or
  with `HALLMARK_EXTRACT=off`). `hallmark extract FILE` prints the guards.
  `docs/PLAN.md` ("The shipped extractor") has the details and limits.
  `Extractor#controllers` (`extractor/controllers.rb`) reads
  `app/controllers`: an entry point that authorizes a record loaded through
  the controllers' current tenant reader (`current_tenant :seller,
  controller: :current_seller`) gets `in_current_tenant` in its exposure,
  and one the app exempts from `verify_authorized` is excused from threat
  10 (`UncheckedRequests`). The Railtie records the app's routes into the
  stamp file at exit (`Collectors::Routes`, `Route`, `StampSet#routes`), and
  routes no test reached become exposures from the rules their code
  authorizes, or coverage lines (`docs/PLAN.md`, "The shipped
  controllers"). Checks a controller makes in its own code before its
  authorize call (`e404 unless product_accessible_by_current_user?(@product)`)
  are read by `MethodTranslator#expression` with controller names renamed
  (`Canonical` aliases: the record's variable to `record`, the current
  tenant and signed-in user readers, `principal ..., controller:`, to the
  policy's names) and ANDed into the exposure by their lower bound
  (`Controllers#checks`); a check that leaves nothing certain lists the
  entry point under coverage (`Coverage#checks_unread`) instead.
- Drift (phase 2 step 2, Oct 19, 2026; `lib/hallmark/drift.rb`,
  `stamp_facts.rb`): `StampFacts` is the one reading of a stamp's facts in
  catalog terms, shared by `Inference` (`#literals`, the inferred guard's
  true facts) and drift (`#[]`, one leaf as true, false or nil, unknown).
  `Guard#evaluate(facts)` is three-valued (opaque leaves unknown). An
  allow-stamp where the extracted upper bound is false, or a deny-stamp
  (raises included) where the lower bound is true, is a `Drift`
  (`Inference#drift`); unknown is never drift, and a rule with a
  hand-written guard has none. `Report` lists drift in its own section with
  the rule's file:line and the stamp's facts, and drift exits 1. The
  matchers fail on drift in the rules they check (`RuleCheck::Result#drift`,
  printed with `Report.drift_lines`; `not_to` fails on it too).
  `docs/PLAN.md` ("The shipped drift").
- DeclarativePolicy front end (phase 2 step 4, Oct 19, 2026;
  `extractor/declarative_translator.rb`, `extractor/declarative_index.rb`):
  abilities from `rule`/`enable`/`prevent`/`delegate`/`overrides`, EE
  modules from `prepend_mod_with`, D3 and D4 hazards as lints that fail the
  check. Record flags (`resource ..., flags:, public_when:`, guard
  `flag(:x)`, modeled by `FlagModel` as fields of one `RecordFlags` atom)
  and `grant ..., when:`. Grape: `Collectors::GrapeHook` names entry points,
  `Extractor::GrapeEndpoints` reads `lib/api`. `hallmark rules` runs rule
  checks from the CLI. `docs/PLAN.md` ("The shipped DeclarativePolicy front
  end").
- Op inference (after the phase 2 gate, Oct 21, 2026; `lib/hallmark/ops.rb`,
  `extractor/routes_file.rb`): `Ops#fetch` is `rule ..., op:`, else a read
  name (`Ops::READ_NAMES`, `READ_PREFIXES`, `READ_SUFFIXES`: `new?`,
  `index_*?`, `*_stats?` and the like), else read when every route reaching
  the rule is a GET or HEAD, else write. Verbs only ever make a rule read
  (Mastodon's reblog POST checks `show?`). Routes are the recorded ones,
  else `Extractor::RoutesFile` (Prism over `config/routes.rb`, acronyms from
  the initializers); a route reaches a rule through stamps or the action's
  authorize calls, with `Controllers::Authorization#named_policy` (`@event`
  names EventPolicy) when the record's class is unknown. Collectors keep
  `Ops.named` (`Mapping#op_for`), which knows no routes. `docs/PLAN.md`
  ("The shipped op inference").
- Hot path (phase 3 step 1, Oct 21, 2026; `bench/hot_path.rb`, `rake
  bench`): whether to stamp is decided before any fact is read, once per
  request (`Collectors.within_entry_point`) and per decision outside one
  (`Collectors.recording?`; `install!(sample_rate:)`); a request reads
  each user's roles in a tenant once (`Request#roles`); `Facts` fills the
  Stamp in place and caches what the mapping fixes; `StampStore.new(capacity:)`
  drops and counts (`#dropped`) when full. Under 20 µs p99 per sampled
  decision on the test shop. `docs/PLAN.md` ("The shipped hot path").
- Live modes (phase 3 step 2, Oct 21, 2026; `configuration.rb`,
  `sinks.rb`, `example.rb`, `railtie.rb`): `HALLMARK_MODE=shadow|sampled`
  collects in any environment, sampled by `HALLMARK_SAMPLE`
  (`Configuration#sample_rate_for`), through a bounded store
  (`#stamp_store`) whose flusher writes to a sink (`Sinks::File`,
  `Sinks::RedisStream` over the app's client, a callable; `c.sink =`), in a
  run named after the deploy (`#write_run`: `REVISION`, `HEROKU_SLUG_COMMIT`,
  `GIT_SHA`). Routes are recorded on `after_routes_loaded` (Rails 7.1+; in
  `after_initialize` the app cannot load them yet). Opt-in hashed ids
  (`HALLMARK_IDS=on`, `HALLMARK_ID_KEY`, refused in test mode): an `Example`
  of "Class:id" references, HMAC'd by the flusher onto a stamp's first line
  only, read back as `StampSet#examples`. `docs/PLAN.md` ("The shipped live
  modes"), `docs/adr/0004`.
- Baseline and watch (phase 3 step 3, Oct 21, 2026; `baseline.rb`,
  `watch.rb`, `watch/`): `hallmark check --baseline OUT` writes
  `Hallmark::Baseline`, one JSON file with the run's stamp lines and per
  check `Exposure#digest(mapping)` and verdict, plus the failing unchecked
  entry points and `Drift#key`s. `hallmark watch --baseline FILE MAPPING`
  seeds `Watch::Stamps` from those lines, tails `Watch::FileTail` (one run's
  files, byte offsets, complete lines) or `Watch::RedisTail` (XREAD,
  redis-rb or redis-client, required only there), re-runs `Inference` over
  all stamps each batch and sends only exposures whose digest changed to
  the solver (a subset `Analysis`; sidecar by default, CLI fallback).
  New is a counterexample on a check not already failing, an unchecked entry
  point or drift not in the baseline; a check that stops failing is
  reported once; unknowns are retried when new stamps touch them. Text,
  `--json`, `--sarif` (`Watch::Log`), `c.on_finding`, and examples
  (`first seen as user h:...`) printed by the watch only. A changed mapping
  file, scope or version makes the baseline stale: every exposure is
  checked once. `docs/PLAN.md` ("The shipped watch").
- Ownership without membership and public actions (Oct 21, 2026):
  `resource ..., owner_outside_tenant: true | :read | :write` (catalog
  `ownsOutsideTenant`, field `Resource.ownerOutside`), and `public_action
  POLICY, RULE..., audience: :anyone | :signed_in, when: <flag guard>`
  (catalog `publicAction[p, audience]`, ORed into the check of an exposure
  whose rules, `Exposure#rules`, all have one). Findings suggest either
  declaration. `docs/PLAN.md` ("The shipped encoding").
- Field policies and restrictions (phase 3 step 4, Oct 21, 2026;
  `mapping.rb`, `restriction.rb`, `witness_facts.rb`): `field_policy
  RESOURCE, :field, <guard>` (`Mapping::FieldPolicy`) and `reads ...,
  field:` (`Exposure#field`, check `safe_<Action>_read_<Resource>_<field>`,
  `Exposure#target` "User.email"; fields only on reads), and `restrict NAME
  do deny role:, op:, resource:, fields:, when: end` in the map block or
  `c.restrict` (threat 11; a denied role must be declared, and counts in
  the record's tenant, or anywhere for a platform role). No new
  signatures: `ModelBuilder#intended` renders `((allowed or publicAction)
  and fieldPolicy and (not (r1)) ...)`. `Finding` names the restriction or
  field policy the witness broke from `WitnessFacts` (the witness as guard
  leaves, three-valued), else prints `intended:`; a field read with no
  policy is listed at the end of the report. `Exposure#digest` adds the
  field, its policy and covering restrictions only when present, so older
  baselines match. Storefront has `Link.revenue` and "staff never see
  buyers". `docs/PLAN.md` ("The shipped field policies and restrictions").
- GraphQL runtime tracing (phase 3 step 6, Oct 21, 2026;
  `collectors/graphql.rb`, `collectors/graphql_trace.rb`): `GraphqlHook`
  gives every `GraphQL::Schema` subclass (at install, then a TracePoint)
  `Trace` through `trace_with` (2.x) or `LegacyTracer` through `tracer`
  (1.x). A multiplex runs inside the controller's entry point
  (`Collectors.within_entry_point`, whose name may now be a callable,
  `Request#entry_point_name`, and whose checks count for the outer one);
  decisions take `Query.field.field` names (aliases resolved, indices and
  `edges`/`nodes`/`node` below the root dropped), built from the response
  path and the document only when stamped, or the operation (`Query`) in
  lazy resolution. Types' own `authorized?` is stamped as
  `Types::X#authorized?` (`ContextPolicy`, user and tenant from `graphql
  current_user:, current_tenant:` in the map block) unless a library
  decided inside it (`Collectors::DECIDED`). G6: `ContextMismatch` lines,
  listed under coverage. `docs/PLAN.md` ("The shipped GraphQL tracer").
- GraphQL schema walk (phase 3 step 5, Oct 21, 2026;
  `extractor/graphql_schema.rb`, `graphql_model.rb`, `graphql_model/`,
  `graphql_check.rb`): `Extractor#graphql` reads `app/graphql` and
  `ee/app/graphql` through a second `SourceIndex` (which now keeps
  class-body calls, `Scope#calls`; class methods as `"self.x"` defs; where a
  class is first opened; and `prepend X` modules): schema roots, types and
  the resources they back (class minus `Types::` and `Type`, or
  `graphql_type`), fields and what they return (lists, connections,
  resolvers, interfaces, unions, `HasNodeField`), and checks: type
  `self.authorized?` (method translator, `Canonical` expression aliases
  for `context[:current_user]`), GitLab's `authorize` through
  `Extractor#ability_guard`, field `def authorized?` blocks, Action Policy's
  `authorize:`/`preauthorize:` (`Extractor#rule_guard`), `scope_items`.
  `GraphqlModel` collapses paths through unmapped types (kept only when
  unchecked), renders relations on resource sigs and `gqlReach_<Type>`, and
  makes `GraphqlCheck`s (`reach_<Type>`, `reach_<Type>_<field>` for fields
  with a field policy), an `AnyExposure` beside `Exposure` in the RBIs,
  added by `Inference` (so `check`, baselines and watch include them) or
  `graphql_schema ROOT` in an analyze block. `Witness` rebuilds the query
  from the instance (`Finding#path`). Lints G4, G5 ("GraphQL hazard").
  `docs/PLAN.md` ("The shipped GraphQL schema walk").
- List scopes (phase 3 step 7, Oct 22, 2026; `list_scope.rb`,
  `extractor/scope_reader.rb`, `collectors/lists.rb`, `inference_lists.rb`):
  `ListScope` names a scope the same in stamps and code (Pundit
  `"LinkPolicy", "Scope#resolve"`; Action Policy `relation_scope(:own)`,
  `scope_for(:data)`; graphql-ruby `scope_items`). `MethodTranslator#scope`
  and `#scope_block` read a scope's body as a rule's, with relation chains
  (`where` pairs through terms, `where.not`, `or`, `merge`, `select`,
  `none`, `user.links` via `Terms#holder`, the user's tenants as the new
  guard term `member`, `some rolesIn[p, r.tenant]`) read as a guard on one
  listed record; `term "scope.x", guard` names a chain or a step; the
  rest is opaque. `Extractor#lists`/`#list`; `GraphqlSchema#scope_guard`
  shares the reader. Collectors: Pundit scope classes' `resolve` wrapped,
  Action Policy `apply_scope` and graphql-ruby `ScopeExtension#after_resolve`
  prepended; a sampled call stamps a class-level list stamp (`Stamp#list`)
  and the facts of at most 3 records the app loads (`ListProbe`, extended
  onto a lazy result); `Facts#read` accepts private readers. Inference:
  list units (`Unit#kind`, `#calls`), one list exposure per entry point and
  resource (`Exposure#kind` :list, `list_<Action>_<Resource>`, `#doing`),
  drift, and coverage's question for lists that may span tenants unless
  `resource ..., lists: :current_tenant`, which adds `r.tenant in cur` to
  the check (M5). `lists ACTION, RES, guard:` in an analyze block; `hallmark
  rules` and `extract` include scopes; G5 lints name the type's list
  checks. Storefront's dashboard list is M5. `docs/PLAN.md` ("The shipped
  list scopes").
- REST serializer fields (phase 3 step 8, Oct 22, 2026;
  `extractor/serializers.rb`, `serializers/{grape_entity,active_model,conditions}.rb`,
  `extractor/grape_presents.rb`, `inference_serializers.rb`):
  `Extractor#serializers` indexes Grape entities and ActiveModel
  serializers (`lib/api`, `app/api`, `ee/lib/ee/api`, `ee/lib/api`,
  `app/serializers`, `ee/app/serializers`, `app/entities`) on its own
  `SourceIndex`; `Shown` fields as written, `Field`s per rendering with
  each condition a guard (`Conditions`: lambdas and serializer methods
  through the translator with the rendered class, the options table, and
  `MethodTranslator#expression`'s new `resolver:` keyword for option reads
  and `Ability.allowed?`/`can?`/`policy(record).rule?` on the record; an
  `alias_method :x, :object` names the record). `Serializers::Rendering`s
  come from `Controllers` (`render json:`, `render_to_body`, branches,
  `serialization_scope`) and `GrapeEndpoints::Presents` (`present ...,
  with:`, forwarding helpers one level, ternary `with:`;
  `Authorization#subject`/`#via`). `Inference::SerializerFields` makes a
  field exposure per entry point, resource and field with a field policy
  or a restriction's `fields:` (base exposures, all ops, or the list, AND
  the conditions' lower bounds), `Exposure#shown_by` (not in the digest),
  and `SerializerNotes`, the report's "REST serializers" section. `serializer
  NAME, resource:` in the map block; `from_code` (`Analysis#add_code`) for
  code-only runs with routes from `config/routes.rb`; `hallmark extract`
  prints serializers and renderings. `examples/rest_shop`. Nested mapped
  records, Jbuilder and other renderers are coverage only (decided Oct 22,
  2026). `docs/PLAN.md` ("The shipped serializer fields").
- Revocation, narrow (phase 3 step 9, Oct 24, 2026; threat 9;
  `extractor/role_reads.rb` and `role_reads/{starts,caches,clearing,delegation}.rb`,
  `collectors/revocations.rb`, `stale_access.rb`): the R1 lint,
  `Extractor#role_reads`, walks call graphs (not guards) from the mapping's
  role readers (a lambda read where it is written), its `term`s and the
  rules and DeclarativePolicy conditions read, through the user, the
  tenant, `self`, `belongs_to` associations, class methods and `delegate`,
  4 calls deep, over model files read lazily by Zeitwerk's naming
  (`app/models`, concerns, `ee/`), to `Rails.cache` reads, the session or
  cookies, token claims and class-level memos of a parameter; a membership,
  principal or tenant callback (`after_commit` and kin, `after_add:` and
  `after_remove:`, Rolify's `rolify`) deleting the same key template, a
  `touch: true` toward a versioned key, or a memo reset clears one; an
  uncleared one is a Lint of kind R1 that fails the check (SARIF
  `hallmark/R1`) unless `cache_ok "Class#method", reason:` accepts it.
  `hallmark extract` prints "Role reads". The test-mode collector
  (`Collectors.install!(revocations:)`, the Railtie in test mode only;
  `tenant ..., within:, soft_delete:, role_names:`) adds an `after_commit`
  to the membership class, notes in process memory the roles a user lost
  in a tenant (from the committed row and foreign keys only), clears the
  pairs before each example (`ActiveRecord::TestFixtures#before_setup`)
  and the request's role reads on each commit, and marks a later allow
  whose fresh roles lack one `after_revocation` (role names; a revoked role
  still held is a `revoked_role_read` line). Inference sets marked stamps
  aside (no guard, coverage region or drift; they still reach their entry
  point) and `StaleAccess` judges each against the unit's guard: false is
  "Stale access after revocation", which fails the check (SARIF
  `hallmark/stale`, baseline `"stale"` keys, watch event `stale`,
  `RuleCheck::Result#stale`, the matchers); explained and unjudged ones go
  to coverage. `examples/revocation_shop` (Active Record on SQLite, Pundit,
  `scenario.rb`). `docs/PLAN.md` ("The shipped revocation").

Not built yet, but designed and validated as hand-written models in
`research/models` (see its README for each check's expected result):
tenancy flaws M4 and M6 (invitations, Rolify grants), role-configuration
checks. Revocation shipped narrowly (above); `revocation.als` stays a
research model.

Parts of the `docs/PLAN.md` "Ruby API sketch" are still design only:
`role_hierarchy` and `conflicts` (`c.solver` is built, with `:cli` and
`:sidecar`; `permits:` is built as `resource ..., permits:`, the explicit
permission on one record, for Gumroad's collaborators; `c.restrict` is
built, Oct 21, 2026).

## Commands

```bash
bundle install
bin/hallmark install-alloy                 # Alloy 6.2.0 to ~/.cache/hallmark, SHA-256 verified; needs Java 17+
bin/hallmark install-sidecar               # also builds the sidecar jar (javac + jar from a JDK 17+); no extra download
bundle exec rake test                      # 611 tests; the 41 integration tests skip without the jar or sidecar
bundle exec rake bench                     # what the collectors add per decision (p50, p99, objects); about 2 min
bundle exec rubocop                        # lint
bundle exec srb tc                         # type-check lib/ against rbi/; `rake` runs tests, rubocop, then this
bin/hallmark check examples/medium_clone/hallmark.rb    # exits 1 (two counterexamples, expected)
bin/hallmark check examples/medium_clone/hallmark_fixed.rb
bin/hallmark check examples/storefront/hallmark.rb      # exits 1 (M2, current-tenant confusion, expected)
bin/hallmark check examples/storefront/hallmark_fixed.rb
bin/hallmark check examples/graphql_shop/hallmark.rb    # exits 1 (G1 to G3 and a G4 hazard, expected)
bin/hallmark check examples/graphql_shop/hallmark_fixed.rb
bin/hallmark check examples/rest_shop/hallmark.rb       # exits 1 (a field policy and a restriction, from code alone)
bin/hallmark check examples/rest_shop/hallmark_fixed.rb
bundle exec ruby -Ilib examples/revocation_shop/scenario.rb           # boots the shop (Rails, SQLite), writes its tmp/hallmark
bin/hallmark check examples/revocation_shop/hallmark.rb               # exits 1 (one R1 lint, one stale access, expected)
bundle exec ruby -Ilib examples/revocation_shop/scenario.rb fixed     # also `soft_delete` (run "softdelete")
bin/hallmark check examples/revocation_shop/hallmark_fixed.rb
HALLMARK_SOLVER=sidecar bin/hallmark check examples/storefront/hallmark.rb   # same findings via the sidecar
bundle exec rspec examples/storefront/link_policy_spec.rb   # the matchers, buggy and fixed; passes (sidecar if built)
bin/hallmark model FILE                    # print the generated Alloy model; the fastest way to debug
bin/hallmark extract examples/storefront/hallmark.rb    # guards read from examples/storefront/app/policies
bin/hallmark rules FILE [POLICY...]        # check each rule on its own, from code and recorded stamps
bin/hallmark check --sarif OUT FILE        # also write what fails as SARIF 2.1.0
bin/hallmark check --baseline OUT FILE     # also write what CI knows (stamps, check digests, verdicts) for watch
bin/hallmark watch --baseline B FILE       # tail live stamps, report what B lacks; --once, --json, --sarif, --redis URL
bundle exec rake fixtures:regenerate       # refresh test/fixtures/{medium_clone,storefront,graphql_shop,rest_shop,revocation_shop} from a real run
java -jar ~/.cache/hallmark/alloy-6.2.0.jar exec -c '*' research/models/tenancy.als
```

Run `rake fixtures:regenerate` after changing `catalog.als`, the model
builder's output, or an example's `hallmark.rb`, then rerun the tests:
`test/report_test.rb` asserts specific witness atoms (such as `User$1`) that
can shift when the model changes. Solver output is deterministic for a given
model; a regeneration with no model change only touches the receipt's
timestamp, so revert that.

Settings come from the environment (`HALLMARK_ALLOY_JAR`, `HALLMARK_JAVA`,
`HALLMARK_SCOPE`, `HALLMARK_TIMEOUT`, `HALLMARK_SOLVER`, `HALLMARK_SAT_SOLVER`,
`HALLMARK_SIDECAR_JAR`, `HALLMARK_SIDECAR_HEAP`, `HALLMARK_STAMPS`,
`HALLMARK_MODE`, `HALLMARK_SAMPLE`, `HALLMARK_IDS`, `HALLMARK_ID_KEY`,
`HALLMARK_RUN`, `HALLMARK_ROOT`, `HALLMARK_EXTRACT`) or
`Hallmark.configure`. `HALLMARK_RUN` names the run the collectors write and
(`c.run`) the run `hallmark check`, an analysis's `stamps` and the matchers'
fallback read from a stamp directory; unset, they read the newest run in
`HALLMARK_STAMPS` (before Oct 19, 2026, reading ignored it, so step 1's
recipes name a stamp file instead). `HALLMARK_ROOT` is the app the extractor reads; the CLI sets it from
the mapping file (the parent of `config/`, else the file's directory).
`HALLMARK_SOLVER` picks the backend (`cli`, the default, or `sidecar`);
until Oct 15, 2026 it named the SAT solver, and a SAT solver name there now
raises with a pointer to `HALLMARK_SAT_SOLVER`. `HALLMARK_SAT_SOLVER=minisat`
or `glucose` uses the native solvers bundled in the jar (including
darwin/arm64), with either backend; the default is SAT4J, pure Java.
`HALLMARK_TIMEOUT` bounds a whole CLI run, or one check in the sidecar.

## How the code fits together

```text
Test suite, Railtie installs collectors              lib/hallmark/railtie.rb, collectors.rb, collectors/*
  (GraphQL: GraphqlHook names field-path entry points, stamps types' authorized?)   collectors/graphql*.rb
  (test mode: Revocations' after_commit notes lost roles; Facts#mark stamps after_revocation)   collectors/revocations.rb
  -> each decision: Collectors::Facts reads facts via the mapping -> Stamp
  -> StampStore: queue, flusher thread, tmp/hallmark/*.jsonl  stamp_store.rb, stamp.rb
Hallmark.analyze block (`stamps` loads a StampSet: Inference builds the exposures and Coverage)
  + Extractor: app/policies parsed with Prism, rules as guards   extractor.rb, extractor/*
    (R1: role reads walked into app/models, cached reads no callback clears)   extractor/role_reads*
  -> StampFacts reads each stamp as guard leaves: Inference's literals, Drift's evaluation   stamp_facts.rb, drift.rb
     (after_revocation stamps set aside, judged by StaleAccess)   stale_access.rb
  + Ops: each rule's op from the mapping, its name, the routes' verbs   ops.rb, extractor/routes_file.rb
  + GraphqlSchema (app/graphql) -> GraphqlModel -> GraphqlChecks   extractor/graphql_schema.rb, graphql_model*.rb, graphql_check.rb
  + list scopes: scope bodies read (scope_reader.rb), list stamps -> list units -> list exposures   inference_lists.rb
  + REST serializers: renderings (controllers, grape_presents) -> fields -> field exposures   extractor/serializers*, inference_serializers.rb
  -> Analysis (Mapping + Exposures, each with a Guard)       lib/hallmark/analysis.rb, mapping.rb, guard.rb
     (field policies and restrictions in the mapping)          restriction.rb
  -> ModelBuilder: Alloy source, one assert + check per exposure   model_builder.rb
     (GraphQL: the shared reachability section, then a reach_ check each)   graphql_model/alloy.rb
  -> Hallmark.solver (c.solver)                                    solver.rb
     Solver::CLI#check: `java -jar alloy.jar exec --type xml`      solver/cli.rb
     Solver::Sidecar#check: JSON-RPC to a long-lived JVM           solver/sidecar.rb, child_process.rb, solver/src/
  -> Receipt: verdict per check (counterexample, none, unknown);  receipt.rb
     CLI witnesses from XML, sidecar witnesses as JSON tuples
  -> Report and Finding: witness explained in app terms, plus drift  report.rb, finding.rb, witness_facts.rb

hallmark watch: Baseline (check --baseline) seeds Watch::Stamps    baseline.rb, watch.rb, watch/*
  -> FileTail or RedisTail lines -> Inference over all stamps -> exposures whose digest changed
  -> a subset Analysis on a warm sidecar -> what the baseline lacks: text, JSON, SARIF, c.on_finding

RSpec: require "hallmark/rspec"                                    lib/hallmark/rspec.rb
  -> matcher finds the mapping (let, configuration, config/hallmark.rb) and the stamps
  -> RuleCheck: one exposure per rule ("LinkPolicy#update?"), one Analysis per matcher   rule_check.rb
  -> Hallmark::RSpec.solver (sidecar unless c.solver chosen), closed after the suite
  -> RuleCheck::Result#lines: Report.finding_lines, so the wording matches `hallmark check`
```

Every exposure becomes:

```alloy
pred allows_<Action>_<op>_<Resource>[p: Principal, r: <Sig>] { <guard> }
assert safe_<Action>_<op>_<Resource> { all p: Principal, r: <Sig> | allows_...[p, r] implies allowed[p, <Op>, r] }
check safe_<Action>_<op>_<Resource> for <scope>
```

In a tenant-aware analysis the predicate and the quantifier also take
`cur: Tenant`, the current tenant, between `p` and `r`. `Finding` reads the
witness from the skolems `$safe_<Action>_<op>_<Resource>_p`, `_r` and `_cur`, so keep
the quantified variables named `p`, `r` and `cur`.

## Alloy facts learned building phase 0

- `receipt.json`'s `values` map is lossy: it keys atoms by their parent
  signature and silently drops some. Use it only for verdicts. Witnesses come
  from `<command>-solution-0.xml` (the A4 XML format).
- A check that holds has no `solution` key in `receipt.json`.
- Atoms from an opened module carry its name (`catalog/User$0`); atoms of
  signatures in the main model do not (`Post$0`). `Naming.atom` strips it.
- Two commands with the same name collide in `receipt.json` (the last wins).
  `Analysis` rejects a duplicate action, op and resource for this reason.
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
- Scope must be 2 or more. Tenancy checks need at least 2 tenant atoms: the
  current-tenant confusion bug (M2 in the plan) is invisible with 1.
- `for N` bounds top-level signatures, and `Principal` includes Anonymous,
  so scope 2 leaves one `User`. When tenants are users that also means one
  tenant, so `ModelBuilder#scope_clause` emits `for 2 but 3 Principal`.
- Which counterexample the solver returns is arbitrary among the valid ones.
  Adding tenancy to the catalog flipped MediumClone's `PostsController#update`
  witness from Anonymous to a signed-in user; `no Tenant and no Membership`
  (equivalent to `no Tenant`) flipped it back. `test/medium_clone_test.rb`
  asserts the anonymous witness, so any catalog change can break it without a
  real regression.
- An expression can branch: `F implies E1 else E2` (used by `rolesFor`).
  Avoid overloading a field name across signatures; `member.p` and
  `within.t` stay unambiguous because each name has one owner.
- The jar targets Java 17 (class file version 61). Bump `ALLOY_VERSION` and
  `AlloyInstaller::SHA256` together.
- The Java API lives in `edu.mit.csail.sdg.parser.CompUtil`,
  `edu.mit.csail.sdg.translator.{TranslateAlloyToKodkod, A4Options, A4Solution}`
  and `edu.mit.csail.sdg.alloy4.A4Reporter` (the old `alloy4compiler` packages
  are gone). Maven Central publishes Alloy 6.2.0 under `org.alloytools`.
- A CLI run of the six MediumClone checks takes about 1 to 2 s, almost all
  JVM start. A warm sidecar answers a Storefront check in about 35 ms.

## Alloy facts learned building the sidecar

- `alloy exec` solves with `TranslateAlloyToKodkod.execute_commandFromBook`,
  default `A4Options`, and `SATFactory.find(name)` (case-insensitive; ids
  `sat4j`, `minisat`, `glucose` and others). `A4Options.solver` is a
  `SATFactory` now, not the old `SatSolver` enum. Doing the same in the shim
  gives the CLI's verdicts and witnesses exactly.
- `A4Tuple.atom(i)` labels atoms as the XML does (`catalog/User$0`), and
  `getAllSkolems()` gives `$<check>_p` style labels, so one decoder fits both.
- `parseEverything_fromFile` resolves `open catalog` relative to the model's
  file; the shim writes both into a scratch directory, as the CLI path does.
- Kodkod logs every translation step at INFO through slf4j-simple to stderr;
  the shim sets `org.slf4j.simpleLogger.defaultLogLevel=warn`. JDK 24+ also
  prints `WARNING:` lines about native access when a native solver loads;
  the client leaves them out of error messages.
- Nothing interrupts a running Kodkod or SAT4J solve, so a timed-out check
  leaves a busy thread; the shim answers and halts, and the client restarts.
- Pigeonhole and Ramsey R(4,4) at 18 vertices solve in seconds thanks to
  symmetry breaking. A reliably slow model for timeout tests is R(4,4) at 60
  vertices, which spends many seconds just translating
  (`test/sidecar_integration_test.rb`).
- `Command` has a 15-argument constructor (pos, nameExpr, label, check,
  overall, bitwidth, maxseq, minprefix, maxprefix, expects, scope,
  additionalExactScopes, commandKeyword, formula, parent); the shim uses it
  to override the overall scope.

## Conventions

- Ruby 3.2+, and the floor stays there (decided Oct 19, 2026; 3.1 apps such as
  GitLab at the gate commit load `lib/` through a local initializer,
  unsupported). Endless methods and anonymous block forwarding are fine, but
  never forward an anonymous `&` from inside another block: Ruby 3.3.0, which
  Forem runs, rejects it with a SyntaxError (check with each Ruby's
  `ruby -wc` on `lib/`);
  `# frozen_string_literal: true` everywhere; the test task runs with warnings
  on and should stay warning-free.
- No runtime dependencies beyond `rexml` and `prism` (`>= 1.2`, for the
  extractor; added Oct 19, 2026, since Ruby 3.2 bundles none and 3.3.0
  bundles 0.19, an older API). No network access at runtime except
  `hallmark install-alloy`. Never vendor the Alloy jar.
- Design rule: never run the solver on a request path. Requests only append
  events.
- Report wording: a passing check means "no counterexample within scope N",
  never "safe" or "verified".
- `bundle exec rubocop` stays clean. Fix offenses rather than adding inline
  disables; change `.rubocop.yml` (with a comment saying why) when a cop
  fights the codebase.
- Sorbet signatures live only in `rbi/`, mirroring `lib/` file for file
  (`lib/hallmark/guard.rb` -> `rbi/hallmark/guard.rbi`), so the gem never
  loads `sorbet-runtime` and users need no Sorbet at all. The gem ships
  `rbi/`, and `srb` picks it up for apps that bundle Hallmark. In `lib/`:
  a `# typed: strict` sigil and no `sig`, `extend T::Sig`, `T.let`, `T.must`
  or any other `T.` call (they raise `NameError` without the runtime).
  Declare instance variables and non-literal constants with `T.let` in the
  RBI instead, and handle nil in plain Ruby (`if (x = ...)`, `|| raise`).
  New or changed methods need their RBI signature in the same change;
  `srb tc` fails without it. `bin/hallmark` is `# typed: true` with no RBI,
  so its helpers stay out of the shipped signatures. The one `lib/` file at
  `# typed: true` is `collectors/graphql_trace.rb` (Oct 21, 2026): its
  per-field hooks forward with `(...)`, the only forwarding that does not
  allocate a keyword Hash per call, and Sorbet cannot sign `...`.
- Never name a method `sig`: Sorbet parses any `x.sig` call as a signature
  declaration. Hence `alloy_sig` on `Mapping::Resource` and `Mapping::Grant`.
- Keep constants in `lib/` to literals Sorbet accepts without `T.let`
  (strings, `%i[...].freeze`). A hash constant with its `T.let` in the RBI
  fails `srb tc` in some runs and passes in others (seen Oct 15, 2026), which
  is why `Guard#to_alloy` is a `case` rather than a lookup table.
- Sorbet checks `lib/`, `rbi/`, `sorbet/rbi/` and `bin/hallmark`
  (`sorbet/config`). Tests and examples are untyped. `sorbet/rbi/gems/` is
  generated by Tapioca (added Oct 15, 2026 for the collectors and Railtie):
  after changing the bundle, run `bundle exec tapioca gems --no-doc` (add
  `--all` to regenerate everything). `sorbet/tapioca/require.rb` loads Rails
  and Action Policy's Rails parts first; without it railties, actionpack and
  `ActionPolicy::Controller` come out empty and `srb tc` fails on unresolved
  constants.
- A prepended hook module calls methods its host provides (`record`,
  `action_name`, `pundit_user`); declare those in the module's RBI.
- The authorization libraries, Grape (added Oct 19, 2026), actionpack,
  railties, and activerecord and sqlite3 (added Oct 23, 2026, for the
  revocations collector; sqlite3 2.x installs precompiled) are test
  dependencies only (Gemfile `:test` group), never the gemspec. `lib/hallmark/collectors.rb`
  requires each hook file only when `defined?` finds its library, and
  `lib/hallmark.rb` requires the Railtie only when `Rails::Railtie` exists.
- Collector tests use `test/support/shop.rb` (a Gumroad-shaped shop with the
  same two rules in each library) and the `collect` test helper, which
  installs the collectors with a temporary stamp store and returns the
  StampSet. `test/railtie_test.rb` boots a real Rails app in a child process.
- Unit tests must run without Java (decode fixtures). Tests that need the jar
  call `require_solver!`, which skips when it is missing; tests that need the
  built sidecar also call `require_sidecar!`. Sidecar client tests use
  `fake_sidecar(mode, state_dir)`, a Ruby process speaking the protocol with
  verdicts from `test/fixtures` (`test/support/fake_sidecar.rb` lists the
  misbehaving modes).
- Matcher tests use `test/support/fixture_solver.rb` (`FixtureSolver`, a
  backend answering from a verdict table, with counterexamples taken from
  the captured Storefront witness and renamed to the check), so they need
  no Java. `test/rspec_run_test.rb` runs RSpec itself in a child process.
  RSpec is a development dependency only; `lib/hallmark/rspec.rb` installs
  itself only when `RSpec.configuration` exists, and its RBI keeps RSpec's
  types `T.untyped` so apps need no RSpec RBIs.
- The sidecar's Java lives in `solver/src` and depends only on the Alloy dist
  jar (it carries its own small JSON parser). Keep it Java 17
  (`--release 17`), and bump `Sidecar::PROTOCOL` on both sides with any
  protocol change. Changing a `.java` file changes the jar's name, so run
  `bin/hallmark install-sidecar` again before the integration tests.
- Prose in docs, comments and commit messages: no em dashes; use commas,
  semicolons or parentheses.
- When a design decision changes, update `docs/PLAN.md` (roadmap status and
  open questions included) in the same change.
- `.gitlab-ci.yml` (ruby:3.4-bookworm plus openjdk-17) runs on every push to
  `main`. Pipelines 1 to 4 (Oct 17 to 19, 2026) failed in `lint`: CI installs
  the bundle under `.cache/bundle` (`BUNDLE_PATH`), and `srb tc` checked every
  installed gem there (6,421 errors). Reproduced and fixed Oct 19, 2026 with
  `--ignore=/.cache/` in `sorbet/config` (rubocop already excluded it).
  Check lint the way CI runs it with `docker run` on `ruby:3.4-bookworm`,
  `BUNDLE_PATH=/app/.cache/bundle`.

## Phase 2 (extractor)

Planned Oct 19, 2026 (`docs/PLAN.md`, "Phase 2 plan"; bounds in
`docs/adr/0003`). The GraphQL schema walk and field-level mapping moved to
phase 3. Steps, in order:

0. Phase 1 loose ends: the CI `lint` job (fixed Oct 19, 2026; see
   Conventions); the Forem run's report wording (fixed Oct 21, 2026:
   `Finding` drops a current tenant the mapping never declared and the
   guard never reads, and picks the pattern from the witness's way in).
1. Extractor core and the Pundit and Action Policy front end
   (`lib/hallmark/extractor/`, `term` in the map block, `hallmark extract`),
   on Gumroad: F6 from its own specs with no probe spec, on both checkouts,
   then gone with the fix. Done Oct 19, 2026 (stamps of run 3's
   differential pair; outputs in
   `~/Repos/hallmark-findings/gumroad-b6c62aa/extract1/`, log "Run 4").
2. Drift (three-valued `Guard#evaluate` over stamp facts; fails `check`).
   Done Oct 19, 2026: no drift on step 1's Gumroad inputs on either
   checkout (38 stamps on rules read from code, all definite and agreeing);
   a wrong `role_admin_for?` term gives 4 (outputs in
   `~/Repos/hallmark-findings/gumroad-b6c62aa/drift2/`, log "Run 5").
3. Static entry points: controller `authorize` calls and filters,
   `verify_authorized` skips, record loading through the current tenant
   (the data-side gap), routes recorded at the end of a test run. Done Oct
   19, 2026 (`Extractor::Controllers`, `Collectors::Routes`,
   `UncheckedRequests`; Gumroad log "Run 5" and "Run 6"). Grape moved to
   step 4. Checks in controller code added the same day: F8's three false
   positives gone, F6 stays, on both checkouts (Gumroad log "Run 7",
   outputs and mappings in `~/Repos/hallmark-findings/gumroad-b6c62aa/extract4/`).
4. DeclarativePolicy front end, on GitLab, with Grape endpoints (collector
   and reader): !132952 from `ProjectPolicy` alone; Forem's finding from
   `ArticlePolicy` alone. Done Oct 19, 2026 (`DeclarativeTranslator`,
   `declarative_index.rb`, record flags and `grant ..., when:`,
   `Collectors::GrapeHook`, `GrapeEndpoints`, `hallmark rules`; GitLab log
   "Phase 2 step 4", Forem log "Phase 2"). Private mapping:
   `~/Repos/hallmark-findings/gitlab-7ce3a7d/step4/`.
5. SARIF (`hallmark check --sarif FILE`). Done Oct 19, 2026 (`Sarif`,
   `Exposure#locations`); the logs validate against the OASIS schema.
6. Gate: the three phase 1 apps on bounded, tenancy-heavy slices plus HCB
   (`a8c6c05`) and Mastodon (`5204e8a`), code only (decided Oct 19, 2026);
   every phase 1 bug from code, compared with SPACE. Run Oct 19 to 21,
   2026: criteria met, 4 confirmed real bugs over 5 apps (one new, live,
   on Gumroad), every check under 2 s with no unknown (`docs/PLAN.md`,
   "Phase 2 gate run"). Passed, decided by Anthony Oct 21, 2026. Private
   summary `~/Repos/hallmark-findings/phase2-gate.md`; per-app logs beside
   it (`mastodon.md` and `hcb.md` new); mappings in each app's `gate2/`
   folder. HCB and Mastodon are blobless clones at `~/Repos/hcb` and
   `~/Repos/mastodon`, not forked; run `bin/hallmark rules` from this
   checkout with `HALLMARK_ROOT` set to the clone and `HALLMARK_STAMPS` at an
   empty directory.

7. After the gate (Oct 21, 2026): the two largest false-positive sources it
   found, op inference (`Ops`, `Extractor::RoutesFile`) and the ownership
   without membership and public actions patterns. `hallmark rules` reruns
   on the gate mappings and on copies with the new declarations
   (`~/Repos/hallmark-findings/{hcb,mastodon}/fixes/`) are in the private
   logs `hcb.md` and `mastodon.md` ("Fixes run"), counts included; keep the
   counts out of this repository.

The extractor reads source and never boots the app, so it runs on the
host's Ruby. Opaque leaves (calls it cannot translate) never reach Alloy:
findings come from the lower bound, the rest is coverage.

## Phase 3 (runtime and GraphQL)

Planned Oct 21, 2026 (`docs/PLAN.md`, "Phase 3 plan"; ids in
`docs/adr/0004`). Decided by Anthony the same day: GitLab proves GraphQL
with a historical fix (graphql-ruby 1.13 at `7ce3a7d`, so the tracer handles
1.x and 2.x); revocation is narrow (lint plus test-mode collector); shadow
mode checks in a `hallmark watch` process, never in app workers; and
`c.restrict`, list scopes, REST serializer fields and HMAC ids join the
phase, which stretches it to about 7 weeks. Steps, in order:

0. Plan into the docs (done Oct 21, 2026).
1. Hot path and benchmark (`bench/hot_path.rb`, `rake bench`): baseline
   first, then sampling before any fact is read, a request-local memo of
   role reads, a bounded event buffer. Budget: Hallmark's own work under
   20 µs p99 per sampled decision; mapping readers reported apart. Done Oct
   21, 2026: met on the test shop (about 3 µs at the median, at most 11 µs
   at p99), 7 to 26 objects per call against 31 to 155 before; the bench
   cycles off, not sampled and on each iteration, since a Rails request's
   own tail is noisier than Hallmark's cost. Numbers in `docs/PLAN.md`.
2. Runtime modes `shadow` and `sampled`, sinks (file, Redis stream over the
   app's client, a callable), run named by deploy revision, opt-in HMAC ids
   as a first-seen example outside the stamp's key. Done Oct 21, 2026; live
   routes are recorded on `after_routes_loaded`, and examples are printed
   beside findings by `watch` (step 3), which knows the stamp behind one.
3. `hallmark check --baseline` and `hallmark watch` (re-checks only
   exposures a new stamp changes, on a warm sidecar). Done Oct 21, 2026;
   inference runs again over all stamps each batch (checking stays
   incremental by digest), and the baseline carries the run's stamp lines
   that seed the watch. Tested on the shop app end to end (test mode for
   the baseline, shadow mode with hashed ids for the cross-seller update).
4. Field-level mapping (`field_policy`) and `c.restrict` (threat 11).
   Done Oct 21, 2026, as planned; restrictions can also be declared in the
   map block (`restrict`), which `c.restrict` calls. Storefront's buggy
   version gains a field policy and a restriction finding (3
   counterexamples in 5 checks), its fixed version none, on both backends.
5. GraphQL static: `Extractor::GraphqlSchema` (Prism over `app/graphql`),
   the reachability model from `research/models/graphql.als`, lints G4 and
   G5, `examples/graphql_shop`. Done Oct 21, 2026: the shop's G1 to G3 and
   G4 found and cleared; GitLab's !132952 found through
   `Query.project.pipelineSchedules` from code alone at `7ce3a7d` and gone
   at `c1a85e83ac3` (mapping and log private: `gitlab-7ce3a7d/step5/`,
   `gitlab.md` "Phase 3 step 5"); witness paths rebuilt in Ruby, not via
   `eval`. GraphQL gate bug shortlist:
   `~/Repos/hallmark-findings/gitlab-graphql-candidates.md`.
6. GraphQL runtime: tracer naming field-path entry points; G6. Done Oct
   21, 2026, before step 5 (which reuses its naming); the GitLab rerun is
   recorded in the private log `gitlab.md` ("Phase 3 step 6").
7. List scopes (M5, G5): scope calls stamped, `Scope#resolve` read. Done
   Oct 22, 2026: Storefront's M5 found and cleared on both backends; HCB's
   and Forem's scope classes read exactly from code (`hallmark rules` on
   copies of the gate mappings, `~/Repos/hallmark-findings/{hcb,forem}/step7/`,
   private logs "Phase 3 step 7"), no real bug. Bench rows added.
8. REST serializer fields (Grape::Entity, ActiveModel::Serializer). Done
   Oct 22, 2026: the REST shop's field policy and restriction findings
   found from code (`from_code`) and cleared on both backends; GitLab's
   field checks (schedule variables, project runner token and import URL)
   pass at `7ce3a7d` and the run is clean at the fix; Mastodon's one field
   finding triaged as a mapping error, no real bug (mappings and logs
   private: `gitlab-7ce3a7d/step8/`, `mastodon/step8/`, logs "Phase 3 step
   8"). Decided by Anthony the same day: nested records are coverage only
   (a later step), a mapping-error field finding counts for step 10's
   field item, and Jbuilder and other renderers wait for phase 4.
9. Revocation, narrow: cached role reads lint; `after_revocation` stamps.
   Done Oct 24, 2026: the revocation shop's cached team role found by the
   R1 lint and as stale access, both gone with its fix, on both backends;
   no R1 on the five gate apps, Forem's four role caches seen cleared
   through Rolify's callbacks; GitLab's !257244/!258088 classified as
   policy logic (M3's family) and reproduced through a restriction at
   `7ce3a7d` and at the 2026 pre-fix commit, gone at !257244's merge (the
   EE Grape endpoints are not read: a follow-up). Mappings and logs
   private: `gitlab-7ce3a7d/step9/`, `{forem,hcb,mastodon}/step9/`,
   `gumroad-b6c62aa/step9/`, logs "Phase 3 step 9". Decided by Anthony
   Oct 23, 2026: the five questions in `docs/PLAN.md` "Phase 3 plan" step 9.
10. Gate (proposed, Anthony decides): budget met on the shop and Gumroad;
    F9 from live traffic in shadow mode at upstream `f3ef06a69`, gone on
    the fix branch; a GitLab historical GraphQL fix found and cleared; one
    field-level or list-scope finding triaged; every check under 10 s with
    no unknown.

## Phase 1 (core gem): the gate

Exit gate: Hallmark runs on three apps, one per authorization library
(Pundit, Action Policy, DeclarativePolicy), with each check under 10 seconds.
Any Rails version is fine; Rails 8 is not required.

### Target apps

Checked Oct 15, 2026 against each app's Gemfile on its default branch:

| Library             | Candidate                                                                                                                                                                              | Why                                                                              | Notes                                                                                                        |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Pundit              | [Forem](https://github.com/forem/forem)                                                                                                                                                | Pundit plus Rolify, Rails 8.0; exercises role mapping                            | Large codebase; start with one area (articles, comments)                                                     |
| Pundit (alternates) | [HCB](https://github.com/hackclub/hcb) (Rails 8.1), [Mastodon](https://github.com/mastodon/mastodon) (Rails 8.1), [rubygems.org](https://github.com/rubygems/rubygems.org) (Rails 8.1) | All list `pundit` in their Gemfiles                                              | HCB's users belong to several organizations, which suits the tenant-aware DSL; confirm by reading its models |
| DeclarativePolicy   | [GitLab](https://gitlab.com/gitlab-org/gitlab)                                                                                                                                         | The only substantial public user; group and project memberships with inheritance | Huge; scope it to one slice, such as `ProjectPolicy` and `IssuePolicy`                                       |
| Action Policy       | [Gumroad](https://github.com/antiwork/gumroad) with its Pundit policies ported to Action Policy (decided Oct 15, 2026)                                                                 | No open-source app uses Action Policy, and a port keeps real app logic           | See "Porting Gumroad to Action Policy" below                                                                 |

Forem is the Pundit gate app (decided Oct 15, 2026). The Gumroad differential
check (step 5 below) is a test of the adapters, not a gate app.

### First run on original Gumroad

Oct 16, 2026: original Gumroad (Pundit 2.3.2, Rails 8.1.3.1) at
`b6c62aacab15d0f22d1002ab831d078a35fb17e7` (`main`, Oct 16, 2026), checked
out at `~/Repos/gumroad` (not forked). This is the commit the Action Policy
port should fork from, so the differential check compares the same code.
Slice: `LinkPolicy` and the ten controllers that authorize a `Link` with it.
The mapping is `config/hallmark.rb` in that checkout (local only, with a
Gemfile path entry); the private findings log is
`~/Repos/hallmark-findings/gumroad.md`, with raw outputs beside it.
Results and the Hallmark gaps it found: `docs/PLAN.md`, "First real-app run:
Gumroad (Pundit)".

To rerun: start Gumroad's services (`COMPOSE_PROJECT_NAME=gumroad docker
compose -f docker/docker-compose-local.yml up -d db redis dynamodb
elasticsearch minio createbuckets copyfixturefiles`), then in the checkout
`CI=true DISABLE_SPRING=1 bin/rspec spec/policies/link_policy_spec.rb <the
controller specs>` (Ruby 3.4.3; `CI=true` because Rails 8's lazy routes break
Devise's `sign_in` in controller specs without eager loading), then `ruby
../namelessnotion/hallmark/bin/hallmark check config/hallmark.rb`. The spec
list is in the findings folder.

### GitLab slice (DeclarativePolicy)

Declared Oct 17, 2026, for the gate's "past security fix reproduced" bug:
[gitlab-org/gitlab!132952](https://gitlab.com/gitlab-org/gitlab/-/merge_requests/132952)
(public, HackerOne, severity::3). Before it, `ProjectPolicy` enabled
`:read_pipeline_schedule` for anyone with `public_access`, so non-members
read pipeline schedules of a public project with "Public pipelines" off.
Pinned at the fix's first parent,
`7ce3a7de2db1048b1ae0802e4e76ed04a282fd07`, shallow-fetched to
`~/Repos/gitlab` (not forked). Slice: `read_pipeline_schedule` on
`ProjectPolicy` and `Ci::PipelineSchedulePolicy`, and the controller, REST
and GraphQL paths that check it. GitLab's own pre-fix
`spec/requests/api/ci/pipeline_schedules_spec.rb` expects the leak ("with
public project", `public_builds: false`), so the stamps should show it with
no probe spec. The mapping is `config/hallmark.rb` in that checkout; the
private log `~/Repos/hallmark-findings/gitlab.md` has a hand-written
preview and the gaps found while mapping (Grape entry points, abilities
checked on a container, visibility levels).

Run Oct 17, 2026 in Docker with GitLab's own CI images (recipe in
`~/Repos/hallmark-findings/gitlab-7ce3a7d/env/`). Hallmark loads through a
local initializer (`config/initializers/zz_hallmark.rb`, `HALLMARK_LIB`),
since this GitLab runs Ruby 3.1 and the gemspec asks for 3.2. Four spec
files, no new failures with the collectors on; 9 checks, 1.7 s for the
whole run, no unknown. One counterexample, the historical bug (a signed-in
non-member reads a schedule that is not public), attached to
`GraphqlController#execute` because the REST API (Grape) stamps carry no
entry point. The controller checks pass but are blind (checked against the
`Project`). Rerun at the fix, `c1a85e83ac3` (only the MR's four files differ): no counterexamples in 9 checks, no unknown; the two leaking allows are denies there. Rerun Oct 19, 2026 with the
controller-hook fix (`HALLMARK_RUN=run4`, outputs in
`~/Repos/hallmark-findings/gitlab-7ce3a7d/run4/`): 435 examples, the same 3
webpack failures, the same entry points with the same stamp counts, and an
identical report (1 counterexample in 9 checks, 2.1 s CLI, 1.6 s sidecar),
so GitLab still meets the gate. GitLab's test environment does not eager
load without `CI`, so the slice's controllers loaded after the hook and
always ran it first. Run `bin/hallmark` from
this checkout with `HALLMARK_STAMPS=~/Repos/gitlab/tmp/hallmark`, not from
`~/Repos/gitlab`, whose `.ruby-version` makes mise build Ruby 3.1.4.

### Forem slice (Pundit)

Run Oct 18, 2026 at `b042765feee028e21f92159c845f615354e24a62` (`main`,
Oct 16, 2026; Pundit 2.3.1, Rolify 6.0.1, Rails 8.0.5, Ruby 3.3.0), a
blobless clone at `~/Repos/forem` (not forked). Slice: `ArticlePolicy` and
`OrganizationPolicy` and the controllers that authorize an `Article` or an
`Organization` with them; organizations are the tenants, and an article's
organization is optional (`tenant_optional: true`, built for this run).
Forem's history has no past authorization fix inside a policy that the
catalog can see, so the bug is live: one finding, confirmed with a probe
spec and reported by Anthony to security@dev.to (Oct 19, 2026); details
only in the private log
`~/Repos/hallmark-findings/forem.md` (keep them out of this repository until
Forem has fixed it). 790 examples, 0 failures with the collectors on; 33
checks in 2.9 s (CLI) and 2.4 s (sidecar), no unknown, 7 counterexamples
from that one finding. Anthony accepted it as Forem's gate bug (Oct 18,
2026), so Forem meets the gate's criteria.

The mapping (`config/hallmark.rb`), a local initializer
(`config/initializers/zz_hallmark.rb`, `HALLMARK_LIB`) and the probe spec are
untracked files in that checkout. Docker recipe in
`~/Repos/hallmark-findings/forem/env/` (Forem's CI steps; the database is on
tmpfs, so reload the schema after a restart). Run `bin/hallmark` from this
checkout with `HALLMARK_STAMPS=~/Repos/forem/tmp/hallmark HALLMARK_RUN=slice`;
Forem's `.ruby-version` (3.3.0) is not installed on the host. `bundle
install` in the container prunes three gems from Forem's `vendor/cache`;
restore them with `git checkout -- vendor/cache`.

Rerun the same day with the `outside_tenants` guard term and the Pundit
direct-call wrapper merged (`HALLMARK_RUN=run3`; outputs in
`~/Repos/hallmark-findings/forem/run3/`): 791 examples, 0 failures, 299
stamps (the policy specs now feed them), 8 counterexamples in 33 checks, the
finding's 7 plus a catalog gap (creating an organization). With the draft
fix applied (`run3/fix/`): 801 examples, 0 failures, 1 counterexample in 35
checks, the catalog gap alone. The rerun first failed twice inside Forem,
both fixed in Hallmark: Ruby 3.3.0 rejects an anonymous block forwarded
from inside a block, and RSpec cannot stub on any instance a method a
prepended module defines.

Rerun Oct 19, 2026 with the controller-hook fix (`HALLMARK_RUN=run4` and
`run4fix`; outputs in `~/Repos/hallmark-findings/forem/run4/`): the same
791 and 801 examples with 0 failures, stamps byte-identical to run3's, and
identical reports (8 counterexamples in 33 checks, then 1 in 35 with the
draft fix; 3.7 s and 2.7 s CLI, about 2.5 s sidecar), so Forem still meets
the gate. Forem does not eager load in tests either: only
`ApplicationController` was loaded when the hook installed, and none of its
filters calls Pundit. The fix run applies `fix/f1-fix.patch` and swaps the
probe for `probes/hallmark_probe_m3_fixed_spec.rb`; revert both after.

### Gumroad Action Policy port

Built and run Oct 19, 2026. The port is a worktree of `~/Repos/gumroad` at
`~/Repos/gumroad-action-policy`, branch `action-policy-port`, forked from
`b6c62aa` (the first Pundit run's commit); local only, not pushed (step 1's
GitLab fork is not made). Three commits: guide phase 1 (`7502225c3`), phase
2 (`72f87bce5`) and a missed Pundit helper (`c311c6287`). The Gemfile path
entry and `config/hallmark.rb` stay uncommitted. Private log:
`~/Repos/hallmark-findings/gumroad.md`, "Run 3"; outputs and patches in
`~/Repos/hallmark-findings/gumroad-action-policy-b6c62aa/`.

Results: the policy specs and 9,614 controller, presenter, policy and
channel examples fail in exactly the same places on both checkouts (local
setup only: no Stripe test credentials, no Vite build). On the slice the
two adapters wrote byte-identical stamps, and `hallmark check` gave
identical reports on both backends: 14 checks, no counterexample, no
unknown, about 2 s per run. With the first run's probe spec, both report F6
and F7. The slice's only real bug is F6 (no security impact found); Anthony
decided on Oct 19, 2026 that it counts as the gate's confirmed real bug, so
Action Policy meets the gate and phase 1's gate is passed. Not reported to
Gumroad (decided Oct 19, 2026): nothing leaks, since the redirect target
denies.

To rerun: run both checkouts' specs one after the other, never at once
(they share the `gumroad_test` database and Elasticsearch's `-test`
indices). In each checkout, with `PATH="$(mise where ruby@3.4.3)/bin:$PATH"`
(rbenv's shims fail on Gumroad's `.ruby-version`), run `HALLMARK_RUN=<id>
CI=true DISABLE_SPRING=1 bin/rspec spec/policies/link_policy_spec.rb
<slice_specs.txt>`, then from this checkout `HALLMARK_STAMPS=<checkout>/tmp/hallmark
bin/hallmark check <checkout>/config/hallmark.rb` (it reads the newest run;
for another, set `HALLMARK_STAMPS` to that run's file). A run
id cannot contain `-`. `HALLMARK_MODE=off` runs the Pundit checkout without
the collectors.

Passing the gate, per app (decided Oct 15, 2026):

- a declared slice (Gumroad: `LinkPolicy` and the controllers that call it);
- every check finishes under 10 s with no unknown;
- every finding triaged as a real bug, a catalog gap or a mapping error, in a
  findings log;
- the tested commit pinned; and
- at least one confirmed real bug: live at the pinned commit, or a past
  security fix reproduced at the commit before it. A seeded bug never counts.

Findings logs for third-party apps stay private, outside this repository and
the public forks. Report a live bug through the project's security policy;
publish only after a fix or the policy's deadline. Historical bugs may be
published at once.

Before building the gate for a target, confirm the app still uses the library
(`grep` its Gemfile.lock and `app/policies`), and record the commit you test
against so results are reproducible.

Target apps live outside this repository, as separate checkouts or forks
pinned to a commit. Never copy their code into Hallmark: Forem, Mastodon and
HCB are AGPL-3.0, GitLab mixes MIT with its proprietary `ee/` directory, and
Hallmark is Apache-2.0. Short excerpts in docs, with a link to the source,
are fine.

### Porting Gumroad to Action Policy

Policy folders compared Oct 15, 2026 by sparse checkout of each default branch:

| App                      | Policy files | Lines | Pundit scope classes | Policy specs | License  |
| ------------------------ | ------------ | ----- | -------------------- | ------------ | -------- |
| Gumroad (`e184d51`)      | 69           | 1,720 | 0                    | 56           | MIT      |
| Mastodon (`a4be641`)     | 48           | 1,017 | 0                    | 43           | AGPL-3.0 |
| Forem (`d8b2ba5`)        | 40           | 1,565 | 3                    | not counted  | AGPL-3.0 |
| HCB (`7d0b932`)          | 96           | 3,748 | 3                    | not counted  | AGPL-3.0 |
| rubygems.org (`a271c27`) | 61           | 1,401 | 59                   | not counted  | MIT      |

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
  current-tenant confusion check (M2 in the plan) on real code.
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

How Gumroad maps (checked Oct 15, 2026 on `main`):

- `Link` is the product model (a legacy name). `link.user` is the seller,
  which is the product's tenant, not its owner: `resource Link, tenant: :user`.
- The seller is a `User`: `TeamMembership` has
  `belongs_to :seller, class_name: "User"`, with roles owner, accountant,
  admin, marketing and support.
  `role_owner_for?(seller)` is `seller == self`, so the tenant option
  `self: :owner` gives each seller an implicit owner membership in itself.
  `role_admin_for?` includes the owner.
- `role_admin_for?` raises `ActiveRecord::RecordNotFound` for a non-member
  instead of returning false. Collectors stamp an exception inside a rule as
  a deny.
- `collaborator_for?(product)` (`collaborating_products`) crosses sellers;
  it maps to the explicit-permission pattern on `Link`:
  `resource "Link", tenant: :user, permits: ->(user, link) { user.collaborator_for?(link) }`.
- `is_team_member` is a bit flag for Gumroad staff, checked first by
  `LinkPolicy#edit?`; it maps to a platform role.

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

Order (decided Oct 15, 2026; the sidecar moved from first to third because
one CLI run already costs a single JVM start for all checks, so it is not on
the gate's critical path):

1. **Tenant-aware catalog and DSL, driven by Gumroad.** Done Oct 15, 2026:
   the catalog, `tenant`/`current_tenant`/`platform_role`/`resource ...,
   tenant:`, tenant-aware guards, the 2-tenant scope floor, and
   `examples/storefront`. Choices made while building it (see `docs/PLAN.md`,
   "The shipped encoding"): a platform role may do anything in any tenant;
   in a tenant-aware mapping users hold only platform roles outside tenants;
   the model checks every current tenant, and `current_tenant` tells the
   collectors where to read it.
2. **Collectors, stamp store and Railtie.** Done Oct 15, 2026, with the rule
   op convention. `test/inferred_findings_test.rb` drives the same rules
   through Action Policy and Pundit and gets the findings of a hand-written
   mapping. Choices (see `docs/PLAN.md`, "The shipped collectors"): facts
   are read through mapping readers, not ActiveRecord hooks; only true facts
   become guard literals; only enforcing calls tie a rule to an entry point;
   an unchecked entry point fails the report unless `allow_unchecked`;
   stamps hold no ids, so no HMAC. Not done: the data-side collector (how
   the entry point loaded the record), so a rule's cross-tenant allow seen
   in a policy spec also counts against entry points that scope the record
   to the current tenant.
3. **Sidecar solver.** Done Oct 15, 2026. Choices (see `docs/PLAN.md`,
   "The shipped sidecar"): built with plain `javac` against the Alloy dist
   jar (no Maven, no new download); jar named by a digest of the sources;
   protocol version 1 adds `version` and `unload`; the CLI stays the default
   backend (a one-shot `hallmark check` pays one JVM start either way), so
   the sidecar is opt-in; the SAT solver setting moved to
   `HALLMARK_SAT_SOLVER`; the CLI also reports a timeout as every check
   unknown. Measured on Storefront: about 35 ms per check warm, against
   about 310 ms per check through the CLI.
4. **RSpec matchers.** Done Oct 16, 2026. Choices (see `docs/PLAN.md`,
   "The shipped matchers"): a matcher checks rules, each rule's guard as a
   check of its own (`RuleCheck`), not entry points; it passes only on no
   counterexample within scope, and fails with its own message on an
   unknown and on a rule with nothing to check (not observed: no
   allow-stamp, no hand-written guard); `satisfy_catalog` covers the rules
   the stamps show plus hand-written ones; the mapping comes from
   `let(:hallmark_mapping)`, the configuration or `config/hallmark.rb`, and
   the stamps from `let(:hallmark_stamps)`, the run being recorded in this
   process, or the latest run; the sidecar is the default inside RSpec
   unless `c.solver`/`HALLMARK_SOLVER` chose (`Configuration#solver_chosen?`);
   the `:hallmark` tag sets the subject to the policy class or name and runs
   tagged groups last (through RSpec's private ordering registry, since
   `register_ordering` ignores changes once `--order` is given). Added
   `rule ..., resource:` for a hand-written guard on a rule no stamp shows.

`bin/hallmark check` exits 1 on any counterexample, unchecked entry point or
drift, else 2 on any unknown,
else 0 (`Report.exit_code`; errors also exit 2). Exposures are keyed by entry point
(`docs/adr/0001`); `Exposure#action` becomes the entry point when the
Railtie lands.

## Open questions (Anthony decides; do not choose)

- Reserving the `hallmark` name on RubyGems.
- Whether any target app needs JRuby, and whether any uses schema-per-tenant.
