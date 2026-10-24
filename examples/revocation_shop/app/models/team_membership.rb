# frozen_string_literal: true

# One user's role on one seller's team; `deleted_at` ends it.
class TeamMembership < ApplicationRecord
  belongs_to :user
  belongs_to :seller, class_name: "User"
end
