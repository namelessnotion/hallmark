# Hallmark

Hallmark checks a Ruby app's role-based authorization against a catalog of
access control patterns and reports every exposure that no pattern allows,
with a concrete counterexample.

## Language

### Model

**Catalog**:
The fixed set of patterns that describe intended access, shared by every app Hallmark checks.
_Avoid_: rule set, policy (the app's code is the policy)

**Pattern**:
One common, intended form of access in the catalog, such as ownership, public read, administrator or explicit permission.

**Principal**:
Whoever makes a request: a signed-in user of the app, or the anonymous principal.
_Avoid_: actor, subject

**Resource**:
A kind of application record that access is checked against, such as a post or a product.
_Avoid_: model, object

**Owner**:
The user a resource belongs to personally, for the ownership pattern; a resource may have none.

**Tenant**:
The account a resource lives in and memberships are scoped to, such as an organization, a group or a Gumroad seller. A tenant may itself be a principal.
_Avoid_: org, organization, account, seller

**Current tenant**:
The tenant a request is acting for, taken from the subdomain, path, session, header or authorization context.
_Avoid_: current org, cur

**Membership**:
A principal's set of roles in one tenant; at most one per principal and tenant.

**Platform role**:
A role that intentionally grants access across tenants, such as the app vendor's support staff.

**Grant**:
An intended permission for every holder of a role to perform an op on a kind of resource, or on specific records (explicit permission).

**Permit**:
One user's explicit permission on one record, held outside any role or tenant, such as a collaborator on another seller's product.

**Mapping**:
The developer's declaration of how the app's classes and roles correspond to the catalog's terms.

### What is checked

**Entry point**:
A place a request enters the app: a controller action, or a GraphQL root field or mutation.
_Avoid_: action, when it means the controller action alone

**Rule**:
One authorization decision the app's policy code defines: a Pundit or Action Policy method such as `update?`, or a DeclarativePolicy ability.
_Avoid_: policy method, ability (except when naming the library's own term)

**Op**:
What an exposure does to a resource: read or write.
_Avoid_: operation (in GraphQL that is a query, mutation or subscription), permission

**Exposure**:
One entry point performing one op on one kind of resource, together with the guard it applies.

**Guard**:
The condition under which the app allows an exposure or a rule, expressed over catalog terms.

**Inferred guard**:
A guard built from the allow-stamps the app actually produced.

**Hand-written guard**:
A guard declared in the mapping; it overrides the inferred guard.

### Evidence

**Stamp**:
One distinct authorization decision, deduplicated: entry point, rule, decision, roles in the record's tenant and the current tenant, and the mapped facts as booleans.
_Avoid_: signature (that is an Alloy sig), shape, event (an event is one occurrence; many collapse into one stamp)

**Allow-stamp**:
A stamp whose decision was allow.

**Deny-stamp**:
A stamp whose decision was deny, including a rule that raised.

**Not observed**:
A combination of facts the app neither allowed nor denied in any stamp; reported as a coverage gap, never as a finding.

**Drift**:
Disagreement between a rule's extracted guard and the decisions stamped at run time: an allow-stamp where the guard's upper bound is false, or a deny-stamp where its lower bound is true.

### Results

**Assay**:
The bounded search for counterexamples across every check in an analysis.
_Avoid_: verification, proof

**Check**:
One question put to the solver: can this exposure's guard allow something no pattern allows?

**Scope**:
The bound on how many atoms of each kind the assay considers.

**Verdict**:
A check's outcome: counterexample, no counterexample within scope N, or unknown.

**Counterexample**:
A concrete principal, roles and record for which the guard allows access that no pattern allows.
_Avoid_: violation, exploit

**No counterexample within scope N**:
The verdict when the assay found nothing within the bound; evidence, not proof.
_Avoid_: safe, verified, holds, passes

**Unknown**:
The verdict when a check ran out of time or memory.

**Witness**:
The atoms of a counterexample as the solver returned them.

**Finding**:
A counterexample explained in the app's terms: who, holding which roles, can do what to whose record, through which entry point.

**Hallmark**:
The report an assay produces: which pattern each exposure matches, and where one matches none.
_Avoid_: certificate, stamp (a stamp is evidence going in)
