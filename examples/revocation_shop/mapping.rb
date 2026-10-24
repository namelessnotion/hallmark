# frozen_string_literal: true

# The revocation shop's mapping, shared by config/hallmark.rb (which the
# Railtie loads in scenario.rb) and the analysis files beside this one.
module RevocationShopMapping
  def self.apply(mapping)
    mapping.instance_eval do
      principal "User"
      # Roles are read from the table, not through the app's own (cached)
      # reader, so a stamp holds what the user really holds now.
      tenant "User", membership: "TeamMembership", member: :user, roles: :role, self: :owner,
                     roles_in: ->(user, seller) { TeamMembership.where(user:, seller:, deleted_at: nil).pluck(:role) },
                     within: :seller, soft_delete: :deleted_at
      current_tenant :seller
      resource "Link", tenant: :user

      grant :owner, :read, "Link"
      grant :owner, :write, "Link"
      grant :admin, :read, "Link"
      grant :admin, :write, "Link"

      # The policy's role check, through the app's reader: the start point
      # that leads the revocation lint to the cache behind it.
      term "%w[owner admin].include?(user.team_role_for(seller))", role(:owner, tenant: :current) |
                                                                   role(:admin, tenant: :current)
    end
    mapping
  end
end
