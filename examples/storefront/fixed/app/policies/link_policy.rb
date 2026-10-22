# frozen_string_literal: true

# Storefront's products, with the seller checks update? and the list scope
# lack in ../../app/policies.
class LinkPolicy < ApplicationPolicy
  def edit?
    team_member? && record.user == seller
  end

  def update?
    return false if record.user != seller

    seller_admin?
  end

  private

  def team_member?
    seller_admin? || user.role_marketing_for?(seller)
  end

  def seller_admin?
    user.role_owner_for?(seller) || user.role_admin_for?(seller)
  end

  # The product dashboard's list: the current seller's products, for its team.
  class Scope
    attr_reader :user, :seller, :scope

    def initialize(context, scope)
      @user = context.user
      @seller = context.seller
      @scope = scope
    end

    def resolve
      return scope.none unless team_member?

      scope.where(user: seller)
    end

    private

    def team_member?
      user.role_owner_for?(seller) || user.role_admin_for?(seller) || user.role_marketing_for?(seller)
    end
  end
end
