# frozen_string_literal: true

# A product as the seller's team sees it. Revenue is meant for the
# seller's owner and admins, but `team_admin?` lets marketing in too.
class LinkSerializer < ActiveModel::Serializer
  attributes :id, :name, :price
  attribute :revenue, if: :team_admin?

  def team_admin?
    seller = object.user
    current_user.role_owner_for?(seller) || current_user.role_admin_for?(seller) ||
      current_user.role_marketing_for?(seller)
  end
end
