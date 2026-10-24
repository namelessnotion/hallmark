# frozen_string_literal: true

# REST shop after the fixes Hallmark points to (fixed/): LinkSerializer
# shows revenue to the seller's owner and admins only, and the staff page's
# serializer no longer shows buyers' emails. See README.md in this folder.
#
# Run: bin/hallmark check examples/rest_shop/hallmark_fixed.rb   (no counterexample)

Hallmark.analyze "REST shop (fixed)" do
  map do
    principal "User"
    tenant "User", membership: "TeamMembership", member: :user, roles: :role, self: :owner
    current_tenant :seller, controller: :current_seller
    platform_role :staff
    resource "Link", tenant: :user

    grant :owner, :read, "Link"
    grant :admin, :read, "Link"
    grant :marketing, :read, "Link"

    %i[owner admin marketing].each do |name|
      term "user.role_#{name}_for?(seller)", role(name, tenant: :current)
      term "user.role_#{name}_for?(record.user)", role(name, tenant: :record)
    end

    field_policy "Link", :revenue, role(:owner, tenant: :record) | role(:admin, tenant: :record)

    restrict("staff never see buyers") { deny role: :staff, op: :read, resource: "Link", fields: %i[buyer_emails] }
  end

  # The fixed app, in fixed/.
  from_code File.join(__dir__, "fixed")
end
