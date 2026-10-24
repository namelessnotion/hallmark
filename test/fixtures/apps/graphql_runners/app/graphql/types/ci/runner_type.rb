# frozen_string_literal: true

module Types
  module Ci
    class RunnerType < Types::BaseObject
      graphql_name "CiRunner"
      authorize :read_runner

      field :description, GraphQL::Types::String, null: true
      field :jobs, Types::Ci::JobType.connection_type, null: true, resolver: Resolvers::Ci::RunnerJobsResolver
    end
  end
end
