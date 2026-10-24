# frozen_string_literal: true

module Types
  class ProjectType < Types::BaseObject
    authorize :read_project

    field :name, GraphQL::Types::String, null: false
    field :jobs, Types::Ci::JobType.connection_type, null: true, authorize: :read_build
  end
end
