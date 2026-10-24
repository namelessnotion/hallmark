# frozen_string_literal: true

# Anyone can sell; a seller's team members act for it with a role.
class User < ApplicationRecord
  has_many :links

  # The user's role on a seller's team: the seller owns its own shop. The
  # role is cached across requests, and nothing clears it when the
  # membership changes (the R1 lint).
  def team_role_for(seller)
    return "owner" if seller == self

    Rails.cache.fetch("team-role/#{id}/#{seller.id}") do
      TeamMembership.where(user: self, seller: seller, deleted_at: nil).pick(:role)
    end
  end
end
