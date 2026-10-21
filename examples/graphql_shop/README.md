# GraphQL shop

The schema of `research/models/graphql.als` written as graphql-ruby source:
organizations own projects, projects bill invoices, and users belong to
organizations as members or admins (the tenant is the organization). Its
API is the schema in `app/graphql`; Hallmark reads it with Prism and never
loads it, so there is no Rails app here, only the schema.

```text
Query.organization(slug:)      -> Organization   checks: member or admin of it
Query.node(id:), nodes(ids:)   -> Project, User  (the types implementing Node)
Organization.projects          -> [Project]      checks: member or admin of its organization
Project.owner                  -> User           checks: nothing
Project.billing                -> Billing        (backs no record; checks nothing)
Billing.invoices               -> [Invoice]      checks: nothing
User.email                                       checks: nothing
Mutation.archiveProject(projectId:)              loads the project; checks nothing of its own
```

The mapping (`hallmark.rb`) says what is intended: members and admins read
their organization and its projects, only admins read invoices, any
signed-in user may see a user's profile (`public_action
"Types::UserType", :authorized?, audience: :signed_in`), and a user's email
is for that user alone (`field_policy "User", :email, owner`).

```bash
bin/hallmark check examples/graphql_shop/hallmark.rb         # exits 1
bin/hallmark check examples/graphql_shop/hallmark_fixed.rb   # exits 0
```

The buggy schema reports three counterexamples in five checks and one
hazard:

- **G2, nested path bypass** (`reach_Invoice`): `InvoiceType` checks
  nothing, "since only admins open the billing page", but a member reaches
  invoices through `query { node(id: ...) { ... on Project { billing {
  invoices { ... } } } } }`. Billing backs no record and checks nothing,
  so the model collapses `Project.billing.invoices` into one step.
- **G3, node lookup bypass** (`reach_User`): `UserType` implements Node and
  has no `authorized?`, so an anonymous visitor fetches any user by global
  ID.
- **G1, field leak** (`reach_User_email`): `email` has no field check, so
  anyone who can see a user reads their email.
- **G4** (hazard): `ArchiveProject` loads the project, whose type check any
  member passes, and checks nothing about archiving it.

`fixed/app/graphql` checks invoices for organization admins in
`InvoiceType.authorized?`, signed-in viewers in `UserType.authorized?`,
the user themself in the email field's `authorized?`, and organization
admins in `ArchiveProject#authorized?`: no counterexample within scope 5,
no hazard. Organizations and projects verify in both.

Nothing here is a Rails app: `Organization`, `Project` and the rest are
names in the mapping, and the `term` lines say what the schema's helper
calls (`member_of?`, `admin_of?`) mean in catalog terms.
