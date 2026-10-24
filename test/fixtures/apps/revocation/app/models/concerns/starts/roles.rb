# frozen_string_literal: true

module Starts
  module Roles
    def concern_role = Rails.cache.fetch("concern/#{id}") { "admin" }
  end
end
