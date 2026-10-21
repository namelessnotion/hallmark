# frozen_string_literal: true

# Storefront, a Gumroad-shaped store: every user can sell products, and a
# seller's team members act for that seller with per-seller roles. The seller
# is itself a User, so the tenant is the User class; products (`Link`, after
# Gumroad's legacy name) live in their seller's tenant and have no personal
# owner. See README.md in this folder for the controller code the guards
# summarize.
#
# Run: bin/hallmark check examples/storefront/hallmark.rb
#      bin/hallmark extract examples/storefront/hallmark.rb   (the guards app/policies gives)

Hallmark.analyze "Storefront" do
  map do
    principal "User"
    tenant "User", membership: "TeamMembership", member: :user, roles: :role, self: :owner
    current_tenant :seller   # the seller the request acts for, chosen in the session
    platform_role :staff     # the vendor's own staff (a flag on User)
    resource "Link", tenant: :user

    grant :owner, :read, "Link"
    grant :owner, :write, "Link"
    grant :admin, :read, "Link"
    grant :admin, :write, "Link"
    grant :marketing, :read, "Link"

    # What the role checks in app/policies mean, for `hallmark extract`.
    term "user.role_owner_for?(seller)", role(:owner, tenant: :current)
    term "user.role_admin_for?(seller)", role(:admin, tenant: :current)
    term "user.role_marketing_for?(seller)", role(:marketing, tenant: :current)

    # A product's revenue is for its seller's owner and admins, not marketing.
    field_policy "Link", :revenue, role(:owner, tenant: :record) | role(:admin, tenant: :record)

    # The vendor's staff support sellers, but never see who bought what.
    restrict("staff never see buyers") { deny role: :staff, op: :read, resource: "Link", fields: %i[buyer_emails] }
  end

  seller_team = role(:owner, tenant: :current) | role(:admin, tenant: :current)
  edit = (seller_team | role(:marketing, tenant: :current)) & in_current_tenant

  # LinksController#edit: the policy checks the role and that the product is the seller's
  reads "LinksController#edit", "Link", guard: edit

  # LinksController#update: the product is loaded by id alone, and the policy
  # checks only the role in the current seller (M2, current-tenant confusion)
  writes "LinksController#update", "Link", guard: seller_team

  # Admin::LinksController#update: staff may change any seller's product
  writes "Admin::LinksController#update", "Link", guard: role(:staff)

  # The edit page also shows the product's revenue, to everyone the page
  # lets in, marketing included (the field policy)
  reads "LinksController#edit", "Link", field: :revenue, guard: edit

  # The staff page shows the product with its buyers' emails (the restriction)
  reads "Admin::LinksController#show", "Link", field: :buyer_emails, guard: role(:staff)
end
