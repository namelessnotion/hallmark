# frozen_string_literal: true

module Types
  module Ci
    # A job has no type check: the field that returns it checks the parent.
    class JobType < Types::BaseObject
      graphql_name "CiJob"
      field_class Types::Ci::JobBaseField

      field :id, GraphQL::Types::ID, null: false
      field :status, GraphQL::Types::String, null: false
      field :trace, GraphQL::Types::String, null: true
      field :project, Types::ProjectType, null: true
    end
  end
end
