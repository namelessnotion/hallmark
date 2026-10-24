# frozen_string_literal: true

# A CI host's GraphQL schema, written for the extractor tests (no app code
# is copied): runners serve jobs of many projects. Never loaded.
class RunnerSchema < GraphQL::Schema
  query Types::QueryType
end
