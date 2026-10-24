Model and policy source for the revocation lint's tests
(`test/role_reads_test.rb`), written for them. Each namespace is one world
with its own principal and membership classes: `Shapes` (cache shapes, none
cleared), `Cleared` and `Untouched` (what clears a cache) and `Starts`
(start points, the walk's limits and lazy loading). Nothing here is loaded.
