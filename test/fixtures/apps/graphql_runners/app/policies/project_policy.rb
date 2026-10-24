# frozen_string_literal: true

class ProjectPolicy < BasePolicy
  condition(:member) { team_member? }

  rule { member | admin }.enable :read_project
  rule { member | admin }.enable :read_build
end
