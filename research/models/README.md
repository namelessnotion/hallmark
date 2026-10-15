# Research models

Hand-written Alloy 6 models behind the design plan. Each one isolates one
class of authorization bug so the encoding can be checked before Hallmark
generates it automatically. They use their own copy of the catalog
(`catalog.als`) and are not loaded by the gem.

Run any of them with the jar Hallmark installs:

```bash
java -jar ~/.cache/hallmark/alloy-6.2.0.jar exec -c '*' tenancy.als
```

"Counterexample" means Alloy found a concrete user, role and record that
break the assertion; "holds" means none exists within the stated scope.
Results below are from Alloy 6.2.0 with the default SAT4J solver.

| Model | Check | Result | What it shows |
| --- | --- | --- | --- |
| `blog.als` | `PostsUpdateIsSafe` | Counterexample | A signed-in user updates a post they do not own |
| `blog.als` | `PostsUpdateFixedIsSafe` | Holds | Adding the ownership check closes it |
| `blog.als` | structural checks | Counterexample | Expected: with no role config, anything goes; see `roles.als` |
| `roles.als` | `NoHierarchyCycles` | Holds | The sample Rolify hierarchy has no cycles |
| `roles.als` | `StaticSoD` | Counterexample | One user may hold both Requester and Approver |
| `roles.als` | `NoEscalationByAssignment` | Counterexample | Support can assign Editor, a role it does not hold |
| `revocation.als` | `NoStaleAccess` | Counterexample | A cached allow survives role revocation (3-step trace) |
| `tenancy.als` | `ProjectsDestroyUnscoped` | Counterexample | M1: admin of one org destroys another org's project |
| `tenancy.als` | `ProjectsUpdateCtx` | Counterexample | M2: admin of the current org edits a project in a different org |
| `tenancy.als` | `ProjectsUpdateCtxFixed` | Holds | Checking `record.tenant == current org` closes M2 |
| `tenancy.als` | `ProjectsEditOwnerOnly` | Counterexample | M3: ownership outlives membership |
| `tenancy.als` | `InvitesStayInAdminsOrg` | Counterexample | M4: invite into an org the inviter does not administer |
| `tenancy.als` | `IndexStaysInCurrentOrg` | Counterexample | M5: list scope spans every org the user belongs to |
| `tenancy.als` | `RolifyAdminStaysInOrg` | Counterexample | M6: a global or class-level Rolify grant reaches every org |
| `tenancy.als` | `ProjectsUpdateCtx` with 1 Org | Holds | The M2 bug is invisible with one org in scope, so Hallmark keeps at least 2 |
| `graphql.als` | `G1_UserEmailField` | Counterexample | Anonymous viewer reads `User.email` through `node(id:)` |
| `graphql.als` | `G2_NestedInvoices` | Counterexample | Non-admin member reads invoices through `organization { projects { invoices } }` |
| `graphql.als` | `G3_NodeLookupUser` | Counterexample | Any User is fetchable by global ID |
| `graphql.als` | `FixedSchema` | Holds | Every type and field guarded as intended |
| `declarative.als` | `D1_ConfidentialPrevent` | Counterexample | `confidential & ~member` prevent rule is too weak |
| `declarative.als` | `D1_Fixed` | Holds | Prevent unless author or `can?(:update_project)` |
| `declarative.als` | `D2_Delegated` | Holds | Plain `delegate` keeps the parent's prevent rules |
| `declarative.als` | `D2_OverridesDropPrevent` | Counterexample | `overrides` drops them, so a blocked author passes |
| `declarative.als` | `D3_CacheScope` | Counterexample | A `scope: :user` condition that reads `@subject` reuses the first project's answer |
