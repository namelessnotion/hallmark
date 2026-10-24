# typed: strict
# frozen_string_literal: true

require_relative "collectors/routes"

module Hallmark
  # Loads `config/hallmark.rb` (the mapping, `Hallmark.configure { |c| c.map
  # { ... } }`) and installs the collectors in the test environment, writing
  # stamps under the app's `tmp/hallmark`. `HALLMARK_MODE=off` (or
  # `c.mode = "off"`) turns them off; `HALLMARK_MODE=test` turns them on in
  # any environment, and so do the live modes, `shadow` and `sampled`,
  # which stamp a share of requests (`c.sample_rate`) through the
  # configured sink with a bounded queue, and record the routes at boot.
  #
  # The file loads after the app has booted, once Rails autoloads app
  # classes, so the mapping may name them by constant (`resource Link`). It
  # loads only when the collectors are on, so development and console boots
  # never load it; `c.mode = "test"` inside it therefore cannot turn them on
  # (use HALLMARK_MODE or set the mode before boot), but `c.mode = "off"` can
  # still turn them off. When the test process exits, the app's routes are
  # recorded beside the stamps (`Collectors::Routes`). A live process may
  # never exit cleanly, so it records them whenever Rails loads them
  # (`after_routes_loaded`, Rails 7.1 and later): at boot when the app eager
  # loads, as production does, so before a forking server forks; on first
  # use otherwise. Inside `after_initialize` the app is not yet initialized
  # and cannot load them. Older Rails records them at exit. In test mode
  # only, the revocations collector watches the mapping's membership class
  # (`Collectors::Revocations`).
  class Railtie < ::Rails::Railtie
    # The first Rails with the `after_routes_loaded` load hook.
    ROUTES_LOADED_HOOK = "7.1"

    config.after_initialize do |app|
      configuration = Hallmark.configuration
      environment = ::Rails.env.to_s
      next unless Collectors.enabled?(configuration.mode, environment)

      config_file = app.root.join("config", "hallmark.rb")
      load config_file.to_s if config_file.exist?
      next unless Collectors.enabled?(configuration.mode, environment)

      mode = configuration.mode || "test"
      configuration.stamps = app.root.join(configuration.stamps).to_s
      configuration.root = app.root.to_s
      Collectors.install!(store: configuration.stamp_store(mode, app.root),
                          sample_rate: configuration.sample_rate_for(mode), revocations: mode == "test")
      if configuration.live?(mode) && ::Rails.gem_version >= Gem::Version.new(ROUTES_LOADED_HOOK)
        ::ActiveSupport.on_load(:after_routes_loaded) { Collectors::Routes.record(app) }
      else
        at_exit { Collectors::Routes.record(app) }
      end
    end
  end
end
