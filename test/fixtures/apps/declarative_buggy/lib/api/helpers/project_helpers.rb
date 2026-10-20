# frozen_string_literal: true

# Helpers every endpoint of the fixture API can call. Never loaded.
module API
  module ProjectHelpers
    def project
      @project ||= find_project!(params[:id])
    end

    # Called with an argument, and naming its ability through a helper, as
    # GitLab's `find_project!` and `read_project_ability` do.
    def find_project!(id)
      project = Project.find(id)
      not_found! unless can?(current_user, read_project_ability, project)
      project
    end

    def read_project_ability
      :read_project
    end
  end
end
