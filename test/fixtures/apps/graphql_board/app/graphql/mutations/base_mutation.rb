# frozen_string_literal: true

module Mutations
  # A base mutation's check is about the request, not the object.
  class BaseMutation < GraphQL::Schema::RelayClassicMutation
    def ready?(**)
      context[:current_user].present?
    end
  end
end
