# Storefront

A small store shaped like [Gumroad](https://github.com/antiwork/gumroad),
written for this example (no Gumroad code is copied). Every user can sell
products. A seller can add team members, who act for that seller with a
per-seller role: owner, admin or marketing. One user can be on several
sellers' teams, and the session records which seller a request acts for.
The vendor's own staff can change any seller's products.

The seller is itself a `User`, so the tenant class is `User`: each seller
holds the owner role in its own tenant (`self: :owner`), and products
(`Link`, after Gumroad's legacy name) live in their seller's tenant with no
personal owner.

The controllers, summarized:

```ruby
class LinksController < ApplicationController
  def edit
    @link = Link.find(params[:id])
    authorize @link   # LinkPolicy#edit?: owner, admin or marketing of current_seller,
                      #                   and @link.user == current_seller
  end

  def update
    @link = Link.find(params[:id])   # any seller's product
    authorize @link   # LinkPolicy#update?: owner or admin of current_seller;
                      #                     never checks @link.user
    @link.update!(link_params)
  end
end
```

`LinkPolicy#update?` checks the role in the current seller but not that the
product belongs to that seller. An admin of one seller can update another
seller's product by id: current-tenant confusion, M2 in `docs/PLAN.md`.

```console
$ bin/hallmark check examples/storefront/hallmark.rb
Hallmark 0.0.1, Storefront, Alloy 6.2.0, scope 5

FAIL  LinksController#update (write Link)
      guard: (role(:owner, tenant: :current) | role(:admin, tenant: :current))
      a signed-in User (User$2) holding roles marketing, owner in the current tenant User$2 (their own) can update a Link (Link$0) in tenant User$1, where they hold no roles
      intended pattern: Explicit permission
      the Link is not in the current tenant; check that it belongs to the tenant the request acts for
ok    LinksController#edit (read Link)
ok    Admin::LinksController#update (write Link)

1 counterexample in 3 checks.
```

`hallmark_fixed.rb` adds `& in_current_tenant` to the update guard (the
policy checks `record.user == seller`), and every check then finds no
counterexample within scope 5.

The bug needs two tenants to show up. Hallmark never checks fewer: the scope
is at least 2, and when tenants are users it raises the principal bound so
that two seller users fit beside the anonymous visitor.

`link_policy_spec.rb` checks the same two rules with the RSpec matchers
(`require "hallmark/rspec"`), once as shipped and once with the fix:

```console
$ bundle exec rspec examples/storefront/link_policy_spec.rb --format documentation
LinkPolicy
  as shipped
    is expected to have no counterexample for edit? within scope 5
    is expected not to satisfy the catalog within scope 5
    explains the current-tenant confusion in update?
  with the seller check
    is expected to satisfy the catalog within scope 5
    is expected to have no counterexample for update? within scope 5

5 examples, 0 failures
```

Its guards are hand-written (`rule "LinkPolicy", :update?, guard: ...`); in
an app the matchers usually infer them from the stamps the rest of the suite
records.
