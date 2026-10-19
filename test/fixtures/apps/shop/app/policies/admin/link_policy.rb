# frozen_string_literal: true

module Admin
  class LinkPolicy < ::LinkPolicy
    def update?
      super || user.staff?
    end
  end
end
