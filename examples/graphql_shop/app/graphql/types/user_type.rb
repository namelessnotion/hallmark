# frozen_string_literal: true

module Types
  # Implements Node with no authorized?, so node(id:) fetches any user (G3),
  # and its email has no field check (G1).
  class UserType < Types::BaseObject
    implements GraphQL::Types::Relay::Node

    field :name, String, null: false
    field :email, String, null: false
  end
end
