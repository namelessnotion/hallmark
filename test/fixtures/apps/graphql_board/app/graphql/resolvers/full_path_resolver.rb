# frozen_string_literal: true

module Resolvers
  module FullPathResolver
    extend ActiveSupport::Concern

    prepended do
      argument :full_path, GraphQL::Types::ID, required: true
    end
  end
end
