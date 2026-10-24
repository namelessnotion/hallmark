# REST shop

Storefront's domain (`examples/storefront`) served as JSON by Rails
controllers, with Pundit policies and ActiveModel::Serializer, and checked
from code alone (`from_code`): no test run, no stamps. Hallmark reads the
routes in `config/routes.rb`, the policies in `app/policies`, the
controllers in `app/controllers` and the serializers in `app/serializers`;
nothing here is loaded.

- `LinksController#show` loads a product through the seller the request
  acts for and authorizes it with `LinkPolicy#show?` (the seller's owner,
  admins and marketing), then renders `LinkSerializer`, whose `revenue`
  field shows `if: :team_admin?`. The field policy says revenue is for the
  seller's owner and admins; `team_admin?` lets marketing in too.
- `Admin::LinksController#show` lets the vendor's staff read any product
  (`Admin::LinkPolicy#show?`) and renders `Admin::LinkSerializer`, which
  shows `buyer_emails`. The restriction "staff never see buyers" forbids
  that.

```bash
bin/hallmark check examples/rest_shop/hallmark.rb         # exits 1: 2 counterexamples in 4 checks
bin/hallmark check examples/rest_shop/hallmark_fixed.rb   # no counterexample in 3 checks
bin/hallmark extract examples/rest_shop/hallmark.rb       # the guards, serializers and renderings read
```

`fixed/` is the same app with both serializers fixed: `team_admin?` checks
the owner and admin roles only, and the staff serializer no longer shows
buyers' emails.
