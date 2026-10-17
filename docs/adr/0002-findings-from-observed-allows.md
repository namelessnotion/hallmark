# Findings come from observed allows; the rest is coverage

An inferred guard has two honest bounds: the OR of its allow-stamps (what the app was seen to allow) and the negation of the OR of its deny-stamps (everything it was never seen to deny). Hallmark checks the lower bound and reports findings only from it, so every finding is a decision the app actually made; the combinations between the two bounds go in a "not observed" coverage section, never in findings. A hand-written guard in the mapping replaces the inferred one.

## Considered options

- **Check the upper bound.** Misses less, but floods the report with counterexamples on fact combinations no test or request ever exercised.
- **Lower bound with no coverage section.** Quiet, but hides untested branches, which is exactly where bugs live.
