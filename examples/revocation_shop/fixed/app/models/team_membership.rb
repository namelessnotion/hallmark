# frozen_string_literal: true

# One user's role on one seller's team; `deleted_at` ends it. Each change
# forgets the role User#team_role_for cached, so the next request reads it
# again.
class TeamMembership < ApplicationRecord
  belongs_to :user
  belongs_to :seller, class_name: "User"

  after_commit :forget_role

  private

  def forget_role = Rails.cache.delete("team-role/#{user_id}/#{seller_id}")
end
