# frozen_string_literal: true

module Types
  module SearchableInterface
    include GraphQL::Schema::Interface

    field :title, String, null: false
  end
end
