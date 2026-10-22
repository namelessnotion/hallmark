# frozen_string_literal: true

# Projects of the user's organizations, and published ones.
class ProjectPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      if user.admin?
        scope.all
      else
        scope.where(organization: user.organizations).or(scope.where(published: true)).order(:name)
      end
    end
  end
end
