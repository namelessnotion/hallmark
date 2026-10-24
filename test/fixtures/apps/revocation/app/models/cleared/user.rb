# frozen_string_literal: true

module Cleared
  class User < ApplicationRecord
    rolify after_remove: :clear_rolify
    has_many :memberships, class_name: "Cleared::Membership", after_remove: :clear_many

    def symbol_role(seller) = Rails.cache.fetch("role/#{id}/#{seller.id}") { "admin" }
    def block_role = Rails.cache.fetch("block-role/#{id}") { "admin" }
    def destroyed_role = Rails.cache.fetch("c-role/#{id}") { "admin" }
    def glob_role(seller) = Rails.cache.fetch("glob-role/#{id}/#{seller.id}") { "admin" }
    def versioned_role = Rails.cache.fetch("v-role/#{cache_key_with_version}") { "admin" }
    def mismatched_role = Rails.cache.fetch("mismatch/#{id}") { "admin" }
    def expiring_role = Rails.cache.fetch("exp-role/#{id}", expires_in: 1.hour) { "admin" }
    def rolify_role = Rails.cache.fetch("rolify-role/#{id}") { "admin" }
    def many_role = Rails.cache.fetch("many-role/#{id}") { "admin" }

    def self.memo_role(user)
      @memo ||= {}
      @memo[user.id] ||= "admin"
    end

    def self.reset_roles!
      @memo = nil
    end

    def forget_destroyed = Rails.cache.delete("c-role/#{id}")

    private

    def clear_rolify(_role) = Rails.cache.delete("rolify-role/#{id}")
    def clear_many(_membership) = Rails.cache.delete("many-role/#{id}")
  end
end
