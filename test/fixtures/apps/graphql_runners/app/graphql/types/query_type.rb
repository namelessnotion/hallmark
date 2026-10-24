# frozen_string_literal: true

module Types
  class QueryType < Types::BaseObject
    field :project, Types::ProjectType, null: true do
      argument :full_path, GraphQL::Types::ID, required: true
    end

    field :runner, Types::Ci::RunnerType, null: true do
      argument :id, GraphQL::Types::ID, required: true
    end
  end
end
