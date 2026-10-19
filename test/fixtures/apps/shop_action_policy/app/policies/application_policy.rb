# frozen_string_literal: true

# The same shop on Action Policy. Never loaded: Hallmark only parses it.
class ApplicationPolicy < ActionPolicy::Base
  authorize :user, :seller, allow_nil: true

  pre_check :require_user

  private

  def require_user
    deny! unless user
  end
end
