# Extracted guards are bounded like inferred ones

The phase 2 extractor turns a rule's Ruby into a guard over catalog terms. A call it cannot translate (a helper outside the policy, a method the mapping names no term for) becomes an opaque leaf that keeps its source and line. Opaque leaves never reach Alloy. Each extracted guard has two bounds: the lower bound sets every opaque leaf to false where it is positive and to true where it is negated, so it holds only where the code allows whatever the call returns; the upper bound does the opposite. Findings come only from the lower bound, as ADR 0002 already requires of stamps, and the combinations between the two bounds are reported as coverage ("depends on `<call>` at file:line"), never as findings.

A rule's checked guard is its hand-written guard when the mapping has one, else the extracted lower bound OR the guard inferred from allow-stamps. Both are things the app certainly allows, so their union is still a lower bound, and stamps keep covering what the extractor cannot read. With no opaque leaf the two bounds coincide and the extracted guard is exact.

## Considered options

- **Opaque leaves as free Alloy predicates.** The solver chooses every unconstrained relation adversarially, so any opaque condition in an allowing branch would be true for everyone: a counterexample on nearly every rule that calls an app helper.
- **Check the upper bound.** Misses less, but reports access that depends on calls Hallmark never evaluated, the same flood ADR 0002 rejects for stamps.
- **Drop rules with any opaque leaf.** Quiet, but most real rules call one helper somewhere, so the extractor would add little.

## Consequences

`Guard` gains an opaque kind that `to_alloy` refuses, so a guard must be bounded before the model builder sees it. Drift (phase 2, step 2) uses both bounds: an allow-stamp outside the upper bound, or a deny-stamp inside the lower bound, means the extractor or a mapped term is wrong.
