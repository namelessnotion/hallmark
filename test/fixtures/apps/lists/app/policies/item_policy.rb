# frozen_string_literal: true

# Ids of the user's organizations, merged.
class ItemPolicy < ApplicationPolicy
  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(user: user).merge(scope.where(organization_id: user.organization_ids)).includes(:tags)
    end
  end
end
