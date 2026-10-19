# typed: strict
# frozen_string_literal: true

module Hallmark
  module Collectors
    # Names the entry point for decisions made while a Grape endpoint runs,
    # such as GitLab's REST API, whose endpoints call `authorize!` through
    # helpers (phase 2 step 4). The name is the HTTP verb and the route's
    # path without the API's prefix, version or format:
    # "GET /projects/:id/pipeline_schedules", as the static reader
    # (`Extractor::GrapeEndpoints`) names it. Unchecked endpoints (threat 10)
    # are not flagged for Grape yet.
    module GrapeHook
      # Prepended on Grape::Endpoint, whose router calls `run`.
      module Run
        def run
          return super unless Collectors.active?

          name = GrapeHook.entry_point(env)
          return super unless name

          Collectors.within_entry_point(name) { super }
        end
      end

      def self.install
        return if @installed

        @installed = true
        ::Grape::Endpoint.prepend(Run)
      end

      # The entry point of the route a Grape env is serving, or nil.
      def self.entry_point(env)
        route = env.is_a?(Hash) ? env.dig("grape.routing_args", :route_info) : nil
        return nil unless route.respond_to?(:origin) && route.respond_to?(:request_method)

        "#{route.request_method} #{GrapeHook.path(route.origin.to_s, route.prefix, route.version)}"
      rescue StandardError => e
        Collectors.warn_once(e)
        nil
      end

      # "/api/:version/projects/:id" with prefix "api" is "/projects/:id".
      def self.path(origin, prefix, version)
        parts = origin.split("/").reject(&:empty?)
        parts.shift if prefix && parts.first == prefix.to_s.delete_prefix("/")
        parts.shift if version && parts.first == ":version"
        "/#{parts.join("/")}"
      end
    end
  end
end
