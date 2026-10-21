# frozen_string_literal: true

class BoardSchema < GraphQL::Schema
  query Types::QueryType
  mutation Types::MutationType
end
