# frozen_string_literal: true

class ProjectPolicy < BasePolicy
  include CrudPolicyHelpers

  condition(:public_project, scope: :subject) { project.public? }
  condition(:public_builds, scope: :subject) { project.public_builds? }
  condition(:archived, scope: :subject) { project.archived? }
  condition(:guest) { team_member? }
  condition(:reporter) { team_reporter? }

  # Cached per user, but reads the project (D3).
  with_scope :user
  condition(:pinned) { @subject.pinned_by?(@user) }

  rule { public_project }.enable :public_access
  rule { reporter | admin }.enable :read_schedule

  # With public pipelines on, anyone who may see the project reads its
  # schedules.
  rule { can?(:public_access) & public_builds }.policy do
    enable :read_schedule
  end

  rule { public_builds & guest }.enable :read_schedule
  rule { anonymous & ~public_project }.prevent_all
  rule { archived }.prevent(*read_update(:schedule))

  # Ruby's && keeps only `reporter` (D4).
  rule { guest && reporter }.enable :update_schedule
  rule { pinned }.enable :star_project

  def project = @subject
end

ProjectPolicy.prepend_mod_with("ProjectPolicy")
