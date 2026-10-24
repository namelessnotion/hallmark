# frozen_string_literal: true

module Admin
  # The vendor's staff may look at any seller's product.
  class LinkPolicy < ApplicationPolicy
    def show?
      user.staff?
    end
  end
end
