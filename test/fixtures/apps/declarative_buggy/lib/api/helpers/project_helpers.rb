# frozen_string_literal: true

# Helpers every endpoint of the fixture API can call. Never loaded.
module API
  module ProjectHelpers
    def project
      @project ||= Project.find(params[:id])
    end
  end
end
