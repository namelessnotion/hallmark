# frozen_string_literal: true

# A product as the seller's team sees it: revenue for the seller's owner
# and admins only.
class LinkSerializer < ActiveModel::Serializer
  attributes :id, :name, :price
  attribute :revenue, if: :team_admin?

  def team_admin?
    seller = object.user
    current_user.role_owner_for?(seller) || current_user.role_admin_for?(seller)
  end
end
