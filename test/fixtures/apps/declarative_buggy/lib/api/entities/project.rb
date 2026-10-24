# frozen_string_literal: true

module API
  module Entities
    # A project, with a token only its admins see. Never loaded.
    class Project < Grape::Entity
      expose :id, :name
      expose :runners_token, if: ->(project, options) { Ability.allowed?(options[:current_user], :read_schedule, project) }
    end
  end
end

API::Entities::Project.prepend_mod_with("API::Entities::Project")
