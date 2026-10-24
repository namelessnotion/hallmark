# frozen_string_literal: true

module Cleared
  class Membership < ApplicationRecord
    belongs_to :user, class_name: "Cleared::User", touch: true
    belongs_to :seller, class_name: "Cleared::User"

    after_commit :forget
    after_commit { Rails.cache.delete("block-role/#{user_id}") }
    after_destroy_commit :forget_destroyed
    after_update_commit :forget_matching, :forget_other
    after_save :reset_memo

    private

    def forget = Rails.cache.delete("role/#{user_id}/#{seller_id}")
    def forget_destroyed = user.forget_destroyed
    def forget_matching = Rails.cache.delete_matched("glob-role/#{user_id}/*")
    def forget_other = Rails.cache.delete("other/#{user_id}")
    def reset_memo = Cleared::User.reset_roles!
  end
end
