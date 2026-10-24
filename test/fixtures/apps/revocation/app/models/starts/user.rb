# frozen_string_literal: true

module Starts
  class User < ApplicationRecord
    include Roles

    delegate :delegated_role, to: :role_helper

    def global_roles = Rails.cache.fetch("global/#{id}") { ["staff"] }
    def seller_roles(seller) = Rails.cache.fetch("seller/#{id}/#{seller.id}") { ["admin"] }
    def policy_role = Rails.cache.fetch("policy/#{id}") { "admin" }
    def dp_role = Rails.cache.fetch("dp/#{id}") { "admin" }
    def elsewhere = Elsewhere::Roles.for(self) || undefined_here

    def role_helper = @role_helper ||= RoleHelper.for(self)

    def deep1 = deep2
    def deep2 = deep3
    def deep3 = deep4
    def deep4 = deep5
    def deep5 = Rails.cache.fetch("deep5/#{id}") { deep6 }
    def deep6 = Rails.cache.fetch("deep6/#{id}") { "admin" }
  end
end
