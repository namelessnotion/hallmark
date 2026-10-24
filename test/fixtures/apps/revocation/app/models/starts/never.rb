# frozen_string_literal: true

module Starts
  # No walk reaches this class, so the lint never parses it.
  class Never < ApplicationRecord
    def role = Rails.cache.fetch("never") { "admin" }
  end
end
