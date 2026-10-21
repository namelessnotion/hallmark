# frozen_string_literal: true

# GraphQL shop after the fixes Hallmark points to (fixed/app/graphql):
# InvoiceType checks for organization admins, UserType for a signed-in
# viewer, the email field for the user themself, and ArchiveProject for
# organization admins. See README.md in this folder.
#
# Run: bin/hallmark check examples/graphql_shop/hallmark_fixed.rb   (no counterexample, no hazard)

Hallmark.analyze "GraphQL shop (fixed)" do
  map do
    principal "User"
    tenant "Organization", membership: "Membership", member: :user, roles: :role
    resource "Organization", tenant: :itself
    resource "Project", tenant: :organization
    resource "Invoice", tenant: :organization
    resource "User", kind: :profile

    grant :member, :read, "Organization"
    grant :admin, :read, "Organization"
    grant :member, :read, "Project"
    grant :admin, :read, "Project"
    grant :admin, :read, "Invoice"

    # Any signed-in user may see another's profile (graphql-ruby calls the
    # type check `authorized?`, as the runtime tracer stamps it).
    public_action "Types::UserType", :authorized?, audience: :signed_in

    # A user's email is for that user alone.
    field_policy "User", :email, owner

    # What the checks in app/graphql mean.
    term "user.member_of?(record)", role(:member, tenant: :record) | role(:admin, tenant: :record)
    term "user.member_of?(record.organization)", role(:member, tenant: :record) | role(:admin, tenant: :record)
    term "user.admin_of?(record.organization)", role(:admin, tenant: :record)
  end

  # The fixed schema, in fixed/app/graphql.
  graphql_schema File.join(__dir__, "fixed")
end
