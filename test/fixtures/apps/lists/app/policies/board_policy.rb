# frozen_string_literal: true

# A block filter, and a SQL string.
class BoardPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.select { |board| board.user == user }
    end
  end
end

class PagePolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where("visible = 1")
    end
  end
end
