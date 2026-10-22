# frozen_string_literal: true

# An association named after the records, and an early exit.
class TaskPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      return scope.none if user.banned?

      user.tasks
    end
  end
end
