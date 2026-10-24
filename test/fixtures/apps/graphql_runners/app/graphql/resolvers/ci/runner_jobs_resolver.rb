# frozen_string_literal: true

module Resolvers
  module Ci
    class RunnerJobsResolver < GraphQL::Schema::Resolver
      type Types::Ci::JobType.connection_type, null: true
      authorize :read_builds
      authorizes_object!

      alias_method :runner, :object

      def resolve
        context[:job_permission] = :read_build

        runner.jobs
      end
    end
  end
end
