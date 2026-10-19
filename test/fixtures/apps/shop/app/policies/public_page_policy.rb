# frozen_string_literal: true

class PublicPagePolicy < ApplicationPolicy
  allow_anonymous!

  def show?
    true
  end
end
