# frozen_string_literal: true

# Storefront's products: owner, admin and marketing of the current seller.
class LinkPolicy < ApplicationPolicy
  def edit?
    team_member? && record.user == seller
  end

  # Never checks whose product it is: an admin of one seller may update
  # another seller's product (M2, current-tenant confusion).
  def update?
    seller_admin?
  end

  private

  def team_member?
    seller_admin? || user.role_marketing_for?(seller)
  end

  def seller_admin?
    user.role_owner_for?(seller) || user.role_admin_for?(seller)
  end
end
