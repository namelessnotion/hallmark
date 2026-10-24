# frozen_string_literal: true

# A minimal Rails app rooted at ARGV[0] (which holds config/hallmark.rb and
# config/routes.rb), serving test/support/shop.rb's controllers; booted in
# a child process by test/support/rails_app.rb and bench_app.rb.

require "logger"
require "rails"
require "action_controller/railtie"
require "hallmark"
require_relative "shop"

class ShopApp < Rails::Application
  config.root = ARGV.fetch(0)
  config.eager_load = ENV["SHOP_EAGER_LOAD"] == "1"
  config.logger = Logger.new(nil)
  config.secret_key_base = "0" * 64
  config.hosts.clear
end
# The routes live in the app's config/routes.rb (written by the test), so
# they are there at boot, when a live mode records them.
ShopApp.initialize!
