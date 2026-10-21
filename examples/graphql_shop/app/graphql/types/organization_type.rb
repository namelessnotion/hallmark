# frozen_string_literal: true

module Types
  # An organization: its members see it and its projects.
  class OrganizationType < Types::BaseObject
    # Members and admins of the organization
    def self.authorized?(object, context)
      super && context[:current_user]&.member_of?(object)
    end

    field :name, String, null: false
    field :projects, Types::ProjectType.connection_type, null: false
  end
end
