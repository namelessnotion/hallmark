# frozen_string_literal: true

module Types
  module Ci
    # Fields of a job reached through a resolver that sets
    # `context[:job_permission]` need that permission on the job, except the
    # public ones.
    class JobBaseField < ::Types::BaseField
      OPEN_FIELDS = %i[id status].freeze

      def authorized?(object, args, ctx)
        user = ctx[:current_user]
        needed = ctx[:job_permission]

        return super if needed.nil? || OPEN_FIELDS.include?(ctx[:current_field].original_name)
        return super if user.can?(needed, object)

        false
      end
    end
  end
end
