# frozen_string_literal: true

module Types
  # The root of every mutation.
  class MutationType < Types::BaseObject
    graphql_name "Mutation"

    field :archive_project, mutation: Mutations::ArchiveProject
  end
end
