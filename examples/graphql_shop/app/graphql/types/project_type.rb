# frozen_string_literal: true

module Types
  # A project, fetched by global ID or through its organization.
  class ProjectType < Types::BaseObject
    implements GraphQL::Types::Relay::Node

    def self.authorized?(object, context)
      super && context[:current_user]&.member_of?(object.organization)
    end

    field :name, String, null: false
    field :owner, Types::UserType, null: false
    field :billing, Types::BillingType, null: false, method: :itself
  end
end
