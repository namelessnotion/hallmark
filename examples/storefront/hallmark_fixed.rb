# frozen_string_literal: true

# Storefront after the fix Hallmark points to: LinksController#update checks
# that the product belongs to the seller the request acts for, as #edit does.
#
# Run: bin/hallmark check examples/storefront/hallmark_fixed.rb

Hallmark.analyze "Storefront (fixed)" do
  map do
    principal "User"
    tenant "User", membership: "TeamMembership", member: :user, roles: :role, self: :owner
    current_tenant :seller
    platform_role :staff
    resource "Link", tenant: :user

    grant :owner, :read, "Link"
    grant :owner, :write, "Link"
    grant :admin, :read, "Link"
    grant :admin, :write, "Link"
    grant :marketing, :read, "Link"
  end

  seller_team = role(:owner, tenant: :current) | role(:admin, tenant: :current)

  reads  "LinksController#edit", "Link",
         guard: (seller_team | role(:marketing, tenant: :current)) & in_current_tenant
  writes "LinksController#update", "Link", guard: seller_team & in_current_tenant
  writes "Admin::LinksController#update", "Link", guard: role(:staff)
end
