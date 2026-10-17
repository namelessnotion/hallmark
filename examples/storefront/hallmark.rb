# frozen_string_literal: true

# Storefront, a Gumroad-shaped store: every user can sell products, and a
# seller's team members act for that seller with per-seller roles. The seller
# is itself a User, so the tenant is the User class; products (`Link`, after
# Gumroad's legacy name) live in their seller's tenant and have no personal
# owner. See README.md in this folder for the controller code the guards
# summarize.
#
# Run: bin/hallmark check examples/storefront/hallmark.rb

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
  end

  seller_team = role(:owner, tenant: :current) | role(:admin, tenant: :current)

  # LinksController#edit: the policy checks the role and that the product is the seller's
  reads "LinksController#edit", "Link",
        guard: (seller_team | role(:marketing, tenant: :current)) & in_current_tenant

  # LinksController#update: the product is loaded by id alone, and the policy
  # checks only the role in the current seller (M2, current-tenant confusion)
  writes "LinksController#update", "Link", guard: seller_team

  # Admin::LinksController#update: staff may change any seller's product
  writes "Admin::LinksController#update", "Link", guard: role(:staff)
end
