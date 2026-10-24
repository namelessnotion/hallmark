# frozen_string_literal: true

# REST shop: Storefront's domain served as JSON by Rails controllers, with
# Pundit policies and ActiveModel::Serializer. A seller's team reads its
# products through LinksController#show, rendered by LinkSerializer, whose
# revenue field is meant for the seller's owner and admins but is also
# shown to marketing; the vendor's staff read any product through
# Admin::LinksController#show, whose serializer shows the buyers' emails.
# Hallmark reads all of it from code: no test run, no stamps. See
# README.md in this folder.
#
# Run: bin/hallmark check examples/rest_shop/hallmark.rb     (exits 1: the field policy and the restriction)
#      bin/hallmark extract examples/rest_shop/hallmark.rb   (the guards, serializers and renderings read)

Hallmark.analyze "REST shop" do
  map do
    principal "User"
    tenant "User", membership: "TeamMembership", member: :user, roles: :role, self: :owner
    current_tenant :seller, controller: :current_seller
    platform_role :staff
    resource "Link", tenant: :user

    grant :owner, :read, "Link"
    grant :admin, :read, "Link"
    grant :marketing, :read, "Link"

    # What the role checks in the policies and serializers mean.
    %i[owner admin marketing].each do |name|
      term "user.role_#{name}_for?(seller)", role(name, tenant: :current)
      term "user.role_#{name}_for?(record.user)", role(name, tenant: :record)
    end

    # A product's revenue is for its seller's owner and admins, not marketing.
    field_policy "Link", :revenue, role(:owner, tenant: :record) | role(:admin, tenant: :record)

    # The vendor's staff support sellers, but never see who bought what.
    restrict("staff never see buyers") { deny role: :staff, op: :read, resource: "Link", fields: %i[buyer_emails] }
  end

  # Entry points from config/routes.rb beside this file, guards from
  # app/policies, fields from app/serializers.
  from_code __dir__
end
