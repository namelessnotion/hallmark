# frozen_string_literal: true

module Shapes
  class User < ApplicationRecord
    has_many :memberships, class_name: "Shapes::Membership"

    def cached_role(seller)
      Rails.cache.fetch("role/#{id}/#{seller.id}") { memberships.find_by(seller: seller)&.role }
    end

    def read_role
      store = Rails.cache
      store.read("read-role/#{id}")
    end

    def session_role = session[:role]
    def cookie_role = cookies.encrypted[:team_role]

    def token_role(token)
      claims = JWT.decode(token, nil, false).first
      claims["role"]
    end

    def instance_memo = @roles ||= memberships.map(&:role)
    def memoized = strong_memoize(:roles) { memberships.map(&:role) }
    def request_store_roles = RequestStore.store[:roles] ||= memberships.map(&:role)
    def safe_store_roles = Gitlab::SafeRequestStore.fetch(:roles) { memberships.map(&:role) }
    def current_roles = Current.roles

    def self.roles_for(user)
      @roles_by_user ||= {}
      @roles_by_user[user.id] ||= user.memberships.map(&:role)
    end

    def self.nobody = @nobody ||= new(name: "nobody")
  end
end
