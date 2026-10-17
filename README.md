# Hallmark for Ruby

Hallmark checks a Ruby app's role-based authorization against a catalog of
access control patterns written in [Alloy](https://alloytools.org), and
reports every declared action that lets someone read or change data no
pattern allows. Each report comes with a concrete counterexample: who,
holding which roles, can do what to whose record.

A hallmark is the mark an assay office strikes to certify what an alloy is
made of. Here the assay is a bounded search, and the hallmark is its report:
which pattern each action matches, and where one matches none. Where nothing
is found, the report says "no counterexample within scope N", never "safe".

## Status

Phase 1 in progress. It works end to end, on hand-written guards or on
guards inferred from what the app's test suite did:

- the pattern catalog (`data/hallmark/catalog.als`), after Near and Jackson's
  SPACE (ICSE 2016): ownership, public objects, authentication, explicit
  permission, user profiles, administrators, plus platform staff; tenancy
  (memberships per tenant, a tenant on every record, the current tenant) is
  a dimension of every pattern
- a mapping and guard DSL, a model generator, two solver backends (the
  Alloy 6.2 command line, and a long-lived JVM sidecar that answers a warm
  check in tens of milliseconds), and a decoder that turns Alloy's witness
  back into app terms
- the MediumClone example, reproducing both bugs the SPACE paper walks through
- the Storefront example, a Gumroad-shaped store reproducing current-tenant
  confusion (an admin of one seller updates another seller's product)
- collectors for Action Policy, Pundit and DeclarativePolicy, installed by a
  Railtie in the test environment, which record each authorization decision
  as a stamp; guards inferred from the stamps; a report of entry points that
  never authorized (threat 10) and of what the tests never exercised
- RSpec matchers (`require "hallmark/rspec"`): `satisfy_catalog` and
  `have_no_counterexample(:update?)` check a policy's rules one at a time,
  on the sidecar by default

The phase 1 deliverables are built; its gate (Hallmark run on one real app
per authorization library, each with a confirmed real bug) is still open.

Not built yet: extracting guards from Pundit, Action Policy and DeclarativePolicy code,
field-level mapping, and the graphql-ruby schema walk (phase 2); shadow and
sampled runtime modes, plus GraphQL tracing (phase 3). The models for those
live in `research/models`.

## Requirements

- Ruby 3.2 or newer
- Java 17 or newer, on `PATH` or set with `HALLMARK_JAVA`; a JDK (with
  `javac` and `jar`) to build the optional solver sidecar

## Quick start

```bash
bundle install
bin/hallmark install-alloy        # downloads Alloy 6.2.0 and verifies its SHA-256
bin/hallmark check examples/medium_clone/hallmark.rb
```

```text
FAIL  UsersController#update (write User)
      guard: logged_in
      a signed-in User (User$1) holding no roles can update the User profile of User$0
      intended pattern: User profiles
FAIL  PostsController#update (write Post)
      guard: no check
      an anonymous visitor can update a Post owned by User$0
      intended pattern: Authentication
```

`hallmark check` exits 1 when it finds a counterexample, else 2 when a check
ran out of time or memory (unknown, never read as "no counterexample"), else
0, so it can gate CI.

### The solver sidecar

By default each analysis starts one JVM for `alloy exec`. The sidecar keeps
one JVM running Alloy for the whole Ruby process, which matters when many
analyses or checks run in one process:

```bash
bin/hallmark install-sidecar      # builds it from solver/src with javac; no download beyond Alloy
HALLMARK_SOLVER=sidecar bin/hallmark check examples/storefront/hallmark.rb
```

Its heap is capped (`HALLMARK_SIDECAR_HEAP`, 512 MB by default) and each
check gets `HALLMARK_TIMEOUT` seconds; a check that runs out is reported as
unknown and the sidecar is restarted for the next one.

## Writing an analysis

```ruby
Hallmark.analyze "Blog" do
  map do
    principal "User"                                    # the signed-in user class
    resource "User", kind: :profile                     # one record per user
    resource "Post", owner: :author, public_if: :published?
    resource "Setting"                                  # no owner, never public
    grant :moderator, :write, "Post"                    # an intended role permission
  end

  reads  "PostsController#show",   "Post", guard: public_record | owner
  writes "PostsController#update", "Post", guard: logged_in & owner
  writes "Admin::PostsController#destroy", "Post", guard: admin
  writes "ModerationController#hide", "Post", guard: role(:moderator)
end
```

Classes can be given as constants or as names in strings; both normalize to
the class name. Constants need the app's classes loaded, which the Railtie
and the RSpec matchers provide and `bin/hallmark` does not, so a file the
command line reads names app classes in strings.

Mapping options for `resource`:

| Option | Meaning | Default |
| --- | --- | --- |
| `owner:` | association naming the owning user | none: records have no owner |
| `kind: :profile` | each record describes exactly one user | `:object` |
| `public_if:` | a predicate (some records are public) or `true` (all are) | never public |
| `tenant:` | association naming the record's tenant | none: the record lives outside tenants |
| `permits:` | for the collectors, a user's explicit permission on one record (a collaborator, a share): a lambda `(user, record)` or a method on the user, returning `true` for every op, or `:read`, `:write` or a list | nobody holds one |

`grant :role, :read_or_write, "Resource"` declares an intended permission:
every holder of the role may read or write every record of that resource.
Without a matching grant, an action guarded only by `role(:name)` is
reported, and the report suggests the `grant` line if the access is intended.

Guards: `none`, `logged_in`, `owner`, `admin`, `role(:name)`,
`public_record`, and `permitted` (the user holds an explicit permission on
the record for the exposure's op; needs `permits:`), combined with `&`, `|`
and `~` (not).

### Tenants

When users hold roles per organization, group or seller, declare the tenant
class. Roles then count only in the tenant they are held in, and every check
covers every pairing of the request's current tenant and the record's.

```ruby
Hallmark.analyze "Storefront" do
  map do
    principal "User"
    tenant "User", membership: "TeamMembership", member: :user, roles: :role, self: :owner
    current_tenant :seller          # where the request's tenant comes from
    platform_role :staff            # intended access across every tenant
    resource "Link", tenant: :user  # products live in their seller's tenant
    grant :admin, :write, "Link"    # admins may write the products of their own tenant
  end

  writes "LinksController#update", "Link",
         guard: role(:admin, tenant: :current) & in_current_tenant
end
```

`self: :owner` is for apps whose tenant is itself a user (a Gumroad seller):
each tenant holds that role in itself. `role(:name, tenant:)` says where the
role must be held: `:current` (the current tenant), `:record` (the record's
tenant) or `:any` (some tenant, an unscoped check). Without `tenant:`, a role
is held outside tenants, which in a tenant-aware mapping only platform roles
are. `in_current_tenant` means the record belongs to the current tenant.

`bin/hallmark model FILE` prints the generated Alloy model, which is the
best way to see exactly what is being checked.

## Checking a Rails app from its test suite

Instead of writing every guard, let the test suite show what the app does.
Put the mapping in `config/hallmark.rb`; in the test environment the
Railtie loads it once the app has booted and installs a collector for each
authorization library the app uses (Action Policy, Pundit,
DeclarativePolicy). With the collectors off (another environment, or
`HALLMARK_MODE=off`) the file is not loaded at all, so `c.mode = "test"`
inside it cannot turn them on; set `HALLMARK_MODE=test` instead. Since
`hallmark check` also reads this file outside the app, it names classes in
strings:

```ruby
# config/hallmark.rb
Hallmark.configure do |c|
  c.map do
    principal "User", roles: ->(user) { user.staff? ? [:staff] : [] }
    tenant "User", membership: "TeamMembership", self: :owner,
                   roles_in: ->(user, seller) { user.team_roles_for(seller) }
    current_tenant :seller                    # read off the policy (Action Policy context, Pundit reader)
    platform_role :staff
    resource "Link", tenant: :user
    grant :admin, :write, "Link"

    rule "LinkPolicy", :publish?, op: :write   # the op, when the name does not say
    allow_unchecked "PagesController#home"     # may run without authorization
  end
end
```

```bash
bin/rails test                            # writes stamps to tmp/hallmark/
bundle exec hallmark check config/hallmark.rb
```

A `Hallmark.analyze` block starts from a copy of this configured mapping, so
its own `map` adds declarations for that analysis only and never changes
what the collectors read.

Each authorization decision becomes a stamp: the entry point (controller
action; none for a call outside a request, such as from a service object or
a policy spec), the rule (`LinkPolicy#update?`), allow or deny, the roles held in
the record's tenant and in the current tenant, and the mapped facts as
booleans (logged in, owner, public, explicit permission, record in the
current tenant). Stamps hold no ids. An exception inside a rule counts as a
deny. Rules a Pundit policy spec checks with `permit` are stamped too, as
queries.

From the stamps, each rule's guard is the OR of the fact combinations it
allowed, and each entry point's guard is the AND of the rules it enforced
(`authorize`, `authorize!`; queries such as `allowed_to?` count toward the
rule but do not tie it to an entry point). A `rule ..., guard:` line in the
map block replaces an inferred guard. Rules named `index?`, `show?` or
`edit?` read; other `?` rules write; DeclarativePolicy abilities need a
`rule ..., op:` line.

The report then adds:

- `FAIL ... finished without an authorization call`: an entry point that
  served a request (status below 400) without calling any rule. A GET or
  HEAD answered with a redirect is listed under coverage instead when other
  requests to the same entry point did call a rule (an action that
  redirects before `authorize`); `allow_unchecked` excuses every request to
  an entry point, so keep it for actions that are public on purpose.
- **Not observed**: per rule, the fact combinations no test allowed or denied.
  These are coverage gaps, never findings: a counterexample is only ever
  built from a decision the app actually made.

## RSpec matchers

```ruby
# spec/policies/link_policy_hallmark_spec.rb
require "hallmark/rspec"

RSpec.describe LinkPolicy, :hallmark do
  it { is_expected.to satisfy_catalog }                    # every rule of LinkPolicy
  it { is_expected.to have_no_counterexample(:update?) }   # one rule's guard, on its own
end
```

A matcher checks rules, not entry points: each rule's guard becomes one
check of its own, named after the rule. It passes only when the check finds
no counterexample within the scope. It fails with the finding worded as
`hallmark check` words it (here from the Storefront example, whose guards
are hand-written):

```text
expected LinkPolicy#update? to have no counterexample within scope 5; 1 counterexample in 1 rule:

FAIL  LinkPolicy#update? (write Link)
      guard: (role(:owner, tenant: :current) | role(:admin, tenant: :current))
      hand-written for LinkPolicy#update?
      a signed-in User (User$2) holding roles marketing, owner in the current tenant User$2 (their own) can update a Link (Link$0) in tenant User$1, where they hold no roles
      intended pattern: Explicit permission
      the Link is not in the current tenant; check that it belongs to the tenant the request acts for
```

It also fails, with its own message, when the solver gave no verdict
(unknown: raise `HALLMARK_TIMEOUT` or lower the scope) and when a rule has
nothing to check: no allow-stamp and no hand-written guard. That last case
is "not observed", a coverage gap rather than a finding, but not a pass.
`satisfy_catalog` covers the rules the stamps show plus those with a
hand-written guard; a rule no test called is not known to it. `not_to`
passes only on a counterexample.

Where the pieces come from:

- **Mapping:** `let(:hallmark_mapping)` in the example group, else the
  configured mapping (the Railtie loads `config/hallmark.rb`), else
  `config/hallmark.rb` under the working directory.
- **Guards:** `rule ..., guard:` in the mapping, else inferred from stamps:
  `let(:hallmark_stamps)` (a `StampSet` or a path), else the run the
  collectors are recording in this process, else the run written last in
  `tmp/hallmark`. A hand-written guard on a rule no stamp shows checks the
  resource the policy is named after (`LinkPolicy` checks `Link`), or the
  one given with `rule ..., resource:`.
- **Solver:** the sidecar, started on the first check and stopped after the
  suite, unless `HALLMARK_SOLVER` or `c.solver` names a backend; the CLI when
  the sidecar is not built. Storefront's five examples take about 1.7 s on
  the sidecar (most of it the JVM start) and 4.3 s on the CLI.

The `:hallmark` tag makes the policy class (or a name in a string) the
subject, since Pundit and Action Policy cannot build a policy without a
user, and runs tagged groups after the rest of the suite, so their guards
are inferred from every stamp the other specs recorded. With parallel test
workers, give the workers one `HALLMARK_RUN` and run the tagged specs after
they finish. A fixed `HALLMARK_RUN` should be unique per suite run (or
`tmp/hallmark` cleared first), since reusing one mixes the old run's stamps
into the new one. `examples/storefront/link_policy_spec.rb` runs both matchers
on the buggy and fixed Storefront:

```bash
bundle exec rspec examples/storefront/link_policy_spec.rb
```

## How it works

Only the collectors run inside the app, while its specs run; everything
from the stamp store down runs afterwards, in CI or on your machine.

![How a Hallmark run flows: the app's specs drive collectors that write stamps; inference, the mapping and the catalog feed the model builder; the solver's verdicts become the report, with coverage gaps beside the findings](docs/pipeline.svg)

1. The mapping becomes Alloy signatures and facts: one signature per
   resource, plus facts for ownership, public visibility and tenants.
2. Each exposure becomes an assertion: whenever its guard allows a principal
   to touch a record, some catalog pattern must allow it too.
3. Alloy searches for a counterexample within a bounded scope (default 5
   atoms per type; SPACE needed 3 for every bug it found). No counterexample
   means none exists within that scope, which is strong evidence, not proof.
   Tenant-aware checks always have room for at least two tenants, since
   cross-tenant bugs cannot show up with one.
4. Counterexamples are read from Alloy's XML instances and explained in the
   app's vocabulary, along with the pattern the guard was probably meant to
   implement.

## Configuration

| Variable | Purpose | Default |
| --- | --- | --- |
| `HALLMARK_ALLOY_JAR` | path to the Alloy jar | `~/.cache/hallmark/alloy-6.2.0.jar` |
| `HALLMARK_JAVA` | Java executable | `java` |
| `HALLMARK_SCOPE` | atoms per type in each check (2 or more) | `5` |
| `HALLMARK_TIMEOUT` | seconds per CLI run, or per check in the sidecar | `120` |
| `HALLMARK_SOLVER` | backend: `cli` (one `alloy exec` per analysis) or `sidecar` | `cli`; the RSpec matchers use the sidecar when it is built |
| `HALLMARK_SAT_SOLVER` | SAT solver: `sat4j`, or the bundled native `minisat` or `glucose` | `sat4j` |
| `HALLMARK_SIDECAR_JAR` | path to the built sidecar | `~/.cache/hallmark/hallmark-solver-<digest>.jar` |
| `HALLMARK_SIDECAR_HEAP` | sidecar heap cap, in MB | `512` |
| `HALLMARK_STAMPS` | where collectors write stamps and `check` reads them | `tmp/hallmark` |
| `HALLMARK_MODE` | `test` to collect in any Rails environment, `off` to never collect | collect in `test` only |
| `HALLMARK_RUN` | run id in stamp file names, shared by parallel test workers | a timestamp |

The same settings are available in Ruby through `Hallmark.configure`.

## Layout

```text
data/hallmark/catalog.als   the pattern catalog shipped with the gem
lib/hallmark/               mapping, guards, model builder, solver clients, decoder
solver/src/                 the solver sidecar (Java, built by `hallmark install-sidecar`)
lib/hallmark/collectors/    runtime hooks for each authorization library and controllers
lib/hallmark/rspec.rb       the RSpec matchers (`require "hallmark/rspec"`)
rbi/                        Sorbet signatures for lib/ (no sorbet-runtime needed)
sorbet/rbi/                 Tapioca-generated RBIs for the gems lib/ hooks into
bin/hallmark                command-line interface (also the gem executable)
examples/medium_clone/      the SPACE paper's example, buggy and fixed
examples/storefront/        a Gumroad-shaped store with per-seller roles, buggy and fixed,
                            and an RSpec spec using the matchers
research/models/            hand-written models for memberships, GraphQL,
                            DeclarativePolicy, revocation and role config
test/                       unit tests (no Java) and integration tests
docs/PLAN.md                the design plan and roadmap
CLAUDE.md                   working notes for contributors and coding agents
```

## Development

```bash
bundle exec rake test
bundle exec rubocop
bundle exec srb tc                     # type-check lib/ against rbi/
bundle exec rake fixtures:regenerate   # after changing the catalog or model builder
bundle exec rspec examples/storefront/link_policy_spec.rb   # the matchers on the real solver
```

Unit tests decode a captured Alloy run in `test/fixtures` and need no Java;
the sidecar client's tests run a fake sidecar written in Ruby
(`test/support/fake_sidecar.rb`). Integration tests run the real jar and the
built sidecar, and skip when either is missing. The
collector tests drive small policies written for them
(`test/support/shop.rb`) through Action Policy, Pundit, DeclarativePolicy
and Action Controller, which are test dependencies only. The matcher tests
answer from the same captured run (`test/support/fixture_solver.rb`) and run
RSpec itself in a child process; RSpec is a development dependency only.

Hallmark is typed with Sorbet, but every signature lives in `rbi/`, so the
gem has no Sorbet dependency at run time. Apps that use Sorbet get the
signatures automatically: `srb` and Tapioca read the `rbi/` directory of
installed gems.

## Prior art

Hallmark builds on Joseph P. Near and Daniel Jackson,
"[Finding Security Bugs in Web Applications using a Catalog of Access Control Patterns](https://groups.csail.mit.edu/sdg/pubs/2016/access-control-patterns-icse2016.pdf)",
ICSE 2016, and on their earlier Rubicon and Derailer tools. Hallmark keeps
SPACE's catalog and mapping idea, and replaces its symbolic execution with
policy-code extraction and runtime observation.

## License

Not chosen yet (Apache-2.0, to match Alloy, or MIT). Until a license file is
added, all rights are reserved.
