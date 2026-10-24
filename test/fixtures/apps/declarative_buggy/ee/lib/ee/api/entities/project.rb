# frozen_string_literal: true

module EE
  module API
    module Entities
      # EE's project fields, prepended to API::Entities::Project. Never loaded.
      module Project
        extend ActiveSupport::Concern

        prepended do
          expose :approvals_before_merge, if: ->(project, _) { project.archived? }
        end
      end
    end
  end
end
