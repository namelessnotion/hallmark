# Revocation shop

Storefront's domain (`examples/storefront`) as a small Rails app on Active
Record, with Pundit and one controller. A seller's admin edits the
seller's products through `LinkPolicy#update?`, which asks
`User#team_role_for(seller)` for the user's role on the seller's team. That
method caches the role in `Rails.cache` across requests, and nothing clears
it when the membership changes, so an admin downgraded to marketing (or
removed from the team) keeps editing until the cache entry goes (threat 9,
stale access after revocation).

Hallmark sees it two ways:

- from code, the revocation lint (R1): the mapping's `term` for the
  policy's role check leads it to `User#team_role_for`, whose
  `Rails.cache.fetch` no callback on `TeamMembership` or `User` clears;
- from a run, the test-mode revocations collector: `scenario.rb` boots the
  app with the collectors on (SQLite in memory, a memory cache), the admin
  updates a product, the membership is downgraded to marketing, and the
  same user updates it again. The second update is allowed through the
  cache and stamped `after_revocation: ["admin"]`; with marketing in the
  current seller, neither the rule's code nor any other allow explains it.

The mapping (`mapping.rb`) reads roles from the table, not through the
app's cached reader, so stamps hold what the user really holds:

```bash
bundle exec ruby -Ilib examples/revocation_shop/scenario.rb               # writes tmp/hallmark (run "scenario")
bin/hallmark check examples/revocation_shop/hallmark.rb                   # exits 1: one R1 lint, one stale access
bundle exec ruby -Ilib examples/revocation_shop/scenario.rb soft_delete   # the membership ended by deleted_at (run "softdelete")
HALLMARK_RUN=softdelete bin/hallmark check examples/revocation_shop/hallmark.rb
bundle exec ruby -Ilib examples/revocation_shop/scenario.rb fixed
bin/hallmark check examples/revocation_shop/hallmark_fixed.rb             # no lint, no stale access, no counterexample
bin/hallmark extract examples/revocation_shop/hallmark.rb                 # the guards and the role reads
```

`fixed/` is the same app with `TeamMembership` deleting the cached role
after each commit, so the downgraded admin's second update is denied.
