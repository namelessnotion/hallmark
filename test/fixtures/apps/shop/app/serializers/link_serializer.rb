# frozen_string_literal: true

# A product as the shop's API shows it, written for the serializer reader's
# tests. Never loaded.
class LinkSerializer < ActiveModel::Serializer
  attributes :id, :name
  attribute :revenue, key: :earnings, if: :team_admin?
  attribute :draft, unless: -> { object.published? }
  attribute :notes, if: -> { instance_options[:preview] }
  attribute :sales_count do
    object.sales.count
  end
  attribute :buyer_emails, if: :staff?
  attribute :stats, if: :stats_visible?
  has_many :variants
  belongs_to :user, serializer: UserSerializer
  has_one :seller_profile, key: :seller
  attribute :margin, if: :margin_visible?

  def team_admin?
    current_user.role_admin_for?(object.user)
  end

  def staff?
    scope.staff?
  end

  def stats_visible?
    policy(object).update?
  end

  def margin_visible?
    object.margin_public?
  end
end
