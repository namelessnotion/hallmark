# frozen_string_literal: true

module API
  module Entities
    # A schedule, exposing what the reader's tests need. Never loaded.
    class Schedule < Grape::Entity
      expose :id, :description
      expose :ref, as: :branch
      expose :owner, using: ::API::Entities::UserBasic
      expose :project, using: "API::Entities::Project"
      expose :token, unless: :hide_tokens
      expose :internal_id, if: { type: :full }
      expose :next_run_at do |schedule, _options|
        schedule.next_run
      end
      expose :links do
        expose :web_url, if: ->(schedule) { schedule.public? }
      end
      expose :status, merge: true, as: :state
      with_options if: ->(_, options) { options[:current_user] } do
        expose :last_editor, if: :with_editor
        expose :notes
      end
      expose :secret, if: ->(_, _) { can_read_secret? }
      expose :audit, if: can_read(:audit)
      expose :legacy
      expose :visibility, if: ->(_, _) { schedule.public? }

      alias_method :schedule, :object

      private

      def can_read_secret?
        options[:current_user] && options[:current_user].admin?
      end
    end
  end
end
