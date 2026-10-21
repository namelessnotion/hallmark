# frozen_string_literal: true

module Types
  # Fixed: signed-in viewers only, and the email to the user alone.
  class UserType < Types::BaseObject
    implements GraphQL::Types::Relay::Node

    def self.authorized?(object, context)
      super && context[:current_user].present?
    end

    field :name, String, null: false
    field :email, String, null: false do
      def authorized?(obj, args, ctx)
        super && obj == ctx[:current_user]
      end
    end
  end
end
