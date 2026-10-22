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

Two more declarations narrow what the catalog allows. A product's revenue is
for its seller's owner and admins (`field_policy "Link", :revenue, ...`), but
the edit page shows it to everyone the page lets in, marketing included. And
the vendor's staff may change any product but must never see who bought it
(`restrict "staff never see buyers"`), which the staff page breaks by
showing buyers' emails (`Link.buyer_emails`, a field with no field policy of
its own, so the report lists it).

The product dashboard (`LinksController#index`) lists products through
`LinkPolicy::Scope`, whose `resolve` keeps every product of every seller the
user works for (`scope.where(user: user.sellers)`, which the mapping names
`member` with a `term`), whichever seller the request acts for. Products are
mapped `lists: :current_tenant`, so a list showing another seller's product
fails: a list spanning tenants, M5 in `docs/PLAN.md`.

```console
$ bin/hallmark check examples/storefront/hallmark.rb
Hallmark 0.0.1, Storefront, Alloy 6.2.0, scope 5

FAIL  LinksController#update (write Link)
      guard: (role(:owner, tenant: :current) | role(:admin, tenant: :current))
      a signed-in User (User$1) holding roles admin, marketing, owner in the current tenant User$1 (their own) can update a Link (Link$0) in tenant User$0, where they hold no roles
      intended pattern: Explicit permission (a grant to a role)
      the Link is not in the current tenant; check that it belongs to the tenant the request acts for
FAIL  LinksController#edit (read Link.revenue)
      guard: (((role(:owner, tenant: :current) | role(:admin, tenant: :current)) | role(:marketing, tenant: :current)) & in_current_tenant)
      a signed-in User (User$1) holding roles marketing in the current tenant User$0 can read the revenue of a Link (Link$3) in the current tenant, which its field policy allows only where (role(:owner, tenant: :record) | role(:admin, tenant: :record))
      intended pattern: Explicit permission (a grant to a role)
      check the code that decides whether Link.revenue is shown, or widen its field policy in the map block if this is intended
FAIL  Admin::LinksController#show (read Link.buyer_emails)
      guard: role(:staff)
      a signed-in User (User$0) holding roles admin, marketing, owner in the current tenant User$0 (their own) and roles staff outside any tenant can read the buyer_emails of a Link (Link$4) in the current tenant, which the restriction "staff never see buyers" forbids
      intended pattern: Explicit permission (a grant to a role)
      exclude holders of :staff in the code, or narrow the restriction "staff never see buyers" if this is intended
FAIL  LinksController#index (list Link)
      guard: member
      a signed-in User (User$1) lists a Link (Link$0) of another User (User$0), where they hold roles admin, while acting for User$1, where they hold roles admin, owner
      intended pattern: Lists stay in the current tenant (lists: :current_tenant)
      the list's scope does not keep to the current tenant; filter it by the tenant the request acts for, or if lists across tenants are intended here, drop `lists: :current_tenant` from Link
ok    LinksController#edit (read Link)
ok    Admin::LinksController#update (write Link)

4 counterexamples in 6 checks.

Fields with no field policy (checked as readable as their record; declare `field_policy` to narrow):
  Admin::LinksController#show (read Link.buyer_emails)
```

`hallmark_fixed.rb` adds `& in_current_tenant` to the update guard (the
policy checks `record.user == seller`), shows revenue to the owner and
admins only, has the staff page read the product without its buyers,
which the field-scoped restriction does not cover, and lists only the
current seller's products to its team (`fixed/app/policies` has the scope
as code); every check then finds no counterexample within scope 5.
`bin/hallmark extract examples/storefront/hallmark.rb` prints the scope as
read from `app/policies` (`member`), and with
`HALLMARK_ROOT=examples/storefront/fixed` the fixed one.

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
