# frozen_string_literal: true

module Ci
  class BuildPolicy < BasePolicy
    condition(:member) { team_member? }

    rule { member | admin }.enable :read_build
  end
end
