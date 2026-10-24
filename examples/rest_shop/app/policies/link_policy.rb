# frozen_string_literal: true

# A product is for its seller's team: owner, admin and marketing.
class LinkPolicy < ApplicationPolicy
  def show?
    team_member? && record.user == seller
  end

  private

  def team_member?
    user.role_owner_for?(seller) || user.role_admin_for?(seller) || user.role_marketing_for?(seller)
  end
end
