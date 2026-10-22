# frozen_string_literal: true

# A local, `where.not` and a join.
class NotePolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      notes = scope.where(user_id: user.id)
      notes.where.not(archived: true).joins(:tags)
    end
  end
end
