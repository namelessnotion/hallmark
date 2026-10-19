# frozen_string_literal: true

# Storefront's products, with the seller check update? lacks in
# ../../app/policies.
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
end
