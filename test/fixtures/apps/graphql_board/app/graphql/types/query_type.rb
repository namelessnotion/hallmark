# frozen_string_literal: true

module Types
  class QueryType < Types::BaseObject
    graphql_name "Query"

    field :board, Types::BoardType, null: true, resolver: Resolvers::BoardResolver
    field :searchable, Types::SearchableInterface, null: true
    field :item, Types::ItemUnion, null: true
    field :cards, [Types::CardType], null: false
  end
end
