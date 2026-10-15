# Hallmark for Ruby

Hallmark checks a Ruby app's role-based authorization against a catalog of
access control patterns written in [Alloy](https://alloytools.org), and
reports every action that lets someone read or change data no pattern
allows. Each report comes with a concrete counterexample: who, holding which
roles, can do what to whose record.

A hallmark is the stamp that certifies what an alloy is made of. This one
certifies an access policy.

## Status

Phase 0 spike. It works end to end on hand-written guards:

- the pattern catalog (`data/hallmark/catalog.als`), after Near and Jackson's
  SPACE (ICSE 2016): ownership, public objects, authentication, explicit
  permission, user profiles, administrators
- a mapping and guard DSL, a model generator, the Alloy 6.2 command-line
  backend, and a decoder that turns Alloy's witness back into app terms
- the MediumClone example, reproducing both bugs the SPACE paper walks through

Not built yet: extracting guards from Pundit, Action Policy and
DeclarativePolicy code (phase 2), runtime collectors (phase 3), the
long-lived JVM sidecar (phase 1), memberships across organizations, and
graphql-ruby. The models for those live in `research/models`.

## Requirements

- Ruby 3.2 or newer
- Java 17 or newer, on `PATH` or set with `HALLMARK_JAVA`

## Quick start

```bash
bundle install
exe/hallmark install-alloy        # downloads Alloy 6.2.0 and verifies its SHA-256
exe/hallmark check examples/medium_clone/hallmark.rb
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

`hallmark check` exits 1 when it finds a counterexample, so it can gate CI.

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

Mapping options for `resource`:

| Option | Meaning | Default |
| --- | --- | --- |
| `owner:` | association naming the owning user | none: records have no owner |
| `kind: :profile` | each record describes exactly one user | `:object` |
| `public_if:` | a predicate (some records are public) or `true` (all are) | never public |

`grant :role, :read_or_write, "Resource"` declares an intended permission:
every holder of the role may read or write every record of that resource.
Without a matching grant, an action guarded only by `role(:name)` is
reported, and the report suggests the `grant` line if the access is intended.

Guards: `none`, `logged_in`, `owner`, `admin`, `role(:name)`,
`public_record`, combined with `&`, `|` and `~` (not).

`exe/hallmark model FILE` prints the generated Alloy model, which is the
best way to see exactly what is being checked.

## How it works

1. The mapping becomes Alloy signatures and facts: one signature per
   resource, plus facts for ownership and public visibility.
2. Each exposure becomes an assertion: whenever its guard allows a principal
   to touch a record, some catalog pattern must allow it too.
3. Alloy searches for a counterexample within a bounded scope (default 5
   atoms per type; SPACE needed 3 for every bug it found). No counterexample
   means none exists within that scope, which is strong evidence, not proof.
4. Counterexamples are read from Alloy's XML instances and explained in the
   app's vocabulary, along with the pattern the guard was probably meant to
   implement.

## Configuration

| Variable | Purpose | Default |
| --- | --- | --- |
| `HALLMARK_ALLOY_JAR` | path to the Alloy jar | `~/.cache/hallmark/alloy-6.2.0.jar` |
| `HALLMARK_JAVA` | Java executable | `java` |
| `HALLMARK_SCOPE` | atoms per type in each check (2 or more) | `5` |
| `HALLMARK_TIMEOUT` | seconds per solver run | `120` |
| `HALLMARK_SOLVER` | Alloy solver name | `SAT4J` |

The same settings are available in Ruby through `Hallmark.configure`.

## Layout

```text
data/hallmark/catalog.als   the pattern catalog shipped with the gem
lib/hallmark/               mapping, guards, model builder, solver, decoder
exe/hallmark                command-line interface
examples/medium_clone/      the SPACE paper's example, buggy and fixed
research/models/            hand-written models for memberships, GraphQL,
                            DeclarativePolicy, revocation and role config
test/                       unit tests (no Java) and integration tests
```

## Development

```bash
bundle exec rake test
```

Unit tests decode a captured Alloy run in `test/fixtures` and need no Java.
Integration tests run the real jar and skip when it is missing.

## Prior art

Hallmark builds on Joseph P. Near and Daniel Jackson,
"[Finding Security Bugs in Web Applications using a Catalog of Access Control Patterns](https://groups.csail.mit.edu/sdg/pubs/2016/access-control-patterns-icse2016.pdf)",
ICSE 2016, and on their earlier Rubicon and Derailer tools. Hallmark keeps
SPACE's catalog and mapping idea, and replaces its symbolic execution with
policy-code extraction and runtime observation.

## License

Not chosen yet (Apache-2.0, to match Alloy, or MIT). Until a license file is
added, all rights are reserved.
