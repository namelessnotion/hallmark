# typed: strict
# frozen_string_literal: true

module Hallmark
  module Collectors
    # Records a Rails app's routes into the stamp store, so the run's stamp
    # file says which entry points exist, including those no test reached.
    # The Railtie calls it when the test process exits: by then Rails 8's
    # lazily loaded routes are usually loaded, and if not they are loaded
    # here, after the tests, so loading them changes nothing a test saw.
    # Routes of mounted engines and redirects (no controller) are skipped.
    module Routes
      def self.record(app, store = Collectors.store)
        return unless store

        app.reload_routes_unless_loaded if app.respond_to?(:reload_routes_unless_loaded)
        app.routes.routes.each do |route|
          entry_point = entry_point(route.defaults)
          next unless entry_point

          store.record(Route.new(entry_point: entry_point, verb: route.verb.to_s, path: route.path.spec.to_s))
        end
        store.flush
      rescue StandardError => e
        Collectors.warn_once(e)
      end

      # "admin/links" and "show" name "Admin::LinksController#show".
      def self.entry_point(defaults)
        controller = defaults[:controller]
        action = defaults[:action]
        return nil unless controller.is_a?(String) && action.is_a?(String)

        "#{ActiveSupport::Inflector.camelize(controller)}Controller##{action}"
      end
    end
  end
end
