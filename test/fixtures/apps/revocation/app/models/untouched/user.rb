# frozen_string_literal: true

module Untouched
  class User < ApplicationRecord
    def versioned_role = Rails.cache.fetch("v-role/#{updated_at.to_i}") { "admin" }
  end
end
