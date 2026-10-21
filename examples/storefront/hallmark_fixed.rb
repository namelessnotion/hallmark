# frozen_string_literal: true

# Storefront after the fixes Hallmark points to: LinksController#update checks
# that the product belongs to the seller the request acts for, as #edit does;
# the edit page shows revenue only to the seller's owner and admins; and the
# staff page no longer shows buyers' emails.
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

    field_policy "Link", :revenue, role(:owner, tenant: :record) | role(:admin, tenant: :record)

    restrict("staff never see buyers") { deny role: :staff, op: :read, resource: "Link", fields: %i[buyer_emails] }
  end

  seller_team = role(:owner, tenant: :current) | role(:admin, tenant: :current)

  reads  "LinksController#edit", "Link",
         guard: (seller_team | role(:marketing, tenant: :current)) & in_current_tenant
  writes "LinksController#update", "Link", guard: seller_team & in_current_tenant
  writes "Admin::LinksController#update", "Link", guard: role(:staff)
  reads  "LinksController#edit", "Link", field: :revenue, guard: seller_team & in_current_tenant
  # The whole record, not its buyers: the restriction covers only the field.
  reads  "Admin::LinksController#show", "Link", guard: role(:staff)
end
