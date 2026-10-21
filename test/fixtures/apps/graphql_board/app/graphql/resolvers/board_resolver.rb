# frozen_string_literal: true

module Resolvers
  class BoardResolver < GraphQL::Schema::Resolver
    prepend FullPathResolver

    type Types::BoardType, null: true

    argument :archived, GraphQL::Types::Boolean, required: false
  end
end
