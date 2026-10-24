# frozen_string_literal: true

module API
  module Entities
    # A schedule with what only its readers see. Never loaded.
    class ScheduleDetails < Schedule
      unexpose :legacy
      expose :description, override: true, if: ->(schedule, opts) { opts[:full] }
      expose :variables, if: ->(schedule, options) { Ability.allowed?(options[:user], :read_schedule, schedule) }
      expose :forks, if: ->(schedule, options) { Ability.allowed?(options[:user], :read_schedule, schedule.project) }
    end
  end
end
