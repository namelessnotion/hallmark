# frozen_string_literal: true

module Ci
  class RunnerPolicy < BasePolicy
    condition(:maintainer) { team_maintainer? }

    rule { maintainer | admin }.enable :read_runner
    rule { maintainer | admin }.enable :read_builds
  end
end
