# frozen_string_literal: true

module Types
  # The root of every query.
  class QueryType < Types::BaseObject
    graphql_name "Query"

    # node(id:) and nodes(ids:) fetch any object whose type implements Node
    include GraphQL::Types::Relay::HasNodeField
    include GraphQL::Types::Relay::HasNodesField

    field :organization, Types::OrganizationType, null: true do
      argument :slug, String, required: true
    end

    def organization(slug:) = Organization.find_by!(slug: slug)
  end
end
