# frozen_string_literal: true

module Mutations
  # Loading the project runs ProjectType's check, which lets any member read
  # it; nothing checks that the member may archive it (G4).
  class ArchiveProject < BaseMutation
    argument :project_id, ID, loads: Types::ProjectType

    field :project, Types::ProjectType, null: true

    def resolve(project:)
      project.update!(archived: true)
      { project: project }
    end
  end
end
