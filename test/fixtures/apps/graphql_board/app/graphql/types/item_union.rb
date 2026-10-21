# frozen_string_literal: true

module Types
  class ItemUnion < GraphQL::Schema::Union
    possible_types Types::BoardType, Types::CardType
  end
end
