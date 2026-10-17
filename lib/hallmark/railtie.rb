# typed: strict
# frozen_string_literal: true

module Hallmark
  # Loads `config/hallmark.rb` (the mapping, `Hallmark.configure { |c| c.map
  # { ... } }`) and installs the collectors in the test environment, writing
  # stamps under the app's `tmp/hallmark`. `HALLMARK_MODE=off` (or
  # `c.mode = "off"`) turns them off; `HALLMARK_MODE=test` turns them on in
  # any environment.
  #
  # The file loads after the app has booted, once Rails autoloads app
  # classes, so the mapping may name them by constant (`resource Link`). It
  # loads only when the collectors are on, so development and console boots
  # never load it; `c.mode = "test"` inside it therefore cannot turn them on
  # (use HALLMARK_MODE or set the mode before boot), but `c.mode = "off"` can
  # still turn them off.
  class Railtie < ::Rails::Railtie
    config.after_initialize do |app|
      configuration = Hallmark.configuration
      environment = ::Rails.env.to_s
      next unless Collectors.enabled?(configuration.mode, environment)

      config_file = app.root.join("config", "hallmark.rb")
      load config_file.to_s if config_file.exist?
      next unless Collectors.enabled?(configuration.mode, environment)

      configuration.stamps = app.root.join(configuration.stamps).to_s
      Collectors.install!
    end
  end
end
