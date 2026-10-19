# frozen_string_literal: true

module API
  # A GitLab-shaped REST API for the fixture's schedules. Never loaded.
  class Schedules < Grape::API
    resource :projects do
      get ":id/schedules" do
        authorize! :read_schedule, project
        present project.schedules
      end

      route_param :id do
        get "schedules/:schedule_id" do
          present schedule
        end

        post "schedules" do
          authorize! :create_schedule, project
        end

        get "status" do
          { ok: true }
        end
      end
    end

    helpers do
      def schedule
        @schedule ||= project.schedules.find(params[:schedule_id]).tap do |schedule|
          not_found! unless can?(current_user, :read_schedule, schedule)
        end
      end
    end
  end
end
