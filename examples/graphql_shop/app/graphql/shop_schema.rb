# frozen_string_literal: true

# A graphql-ruby schema Hallmark reads from source (never loaded): organizations
# own projects, projects bill invoices, and users belong to organizations.
class ShopSchema < GraphQL::Schema
  query Types::QueryType
  mutation Types::MutationType
end
