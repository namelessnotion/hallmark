# frozen_string_literal: true

# The seller's owner and admins edit the seller's products.
class LinkPolicy < ApplicationPolicy
  def update? = seller_admin? && record.user == seller

  private

  def seller_admin? = %w[owner admin].include?(user.team_role_for(seller))
end
