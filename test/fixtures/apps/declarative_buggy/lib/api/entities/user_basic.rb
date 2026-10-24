# frozen_string_literal: true

module API
  module Entities
    # A user as other entities nest one. Never loaded.
    class UserBasic < Grape::Entity
      expose :id, :username
    end
  end
end
