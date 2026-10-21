# frozen_string_literal: true

module Mutations
  # Fixed: only the organization's admins archive its projects.
  class ArchiveProject < BaseMutation
    argument :project_id, ID, loads: Types::ProjectType

    field :project, Types::ProjectType, null: true

    def authorized?(project:)
      super && context[:current_user]&.admin_of?(project.organization)
    end

    def resolve(project:)
      project.update!(archived: true)
      { project: project }
    end
  end
end
