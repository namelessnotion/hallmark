# frozen_string_literal: true

# Boots a minimal Rails app rooted at ARGV[0] (which holds config/hallmark.rb),
# serves two requests and prints what the collectors did as JSON. Run by
# test/railtie_test.rb in a child process, so Rails state stays out of the
# other tests.

require "json"
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
ShopApp.initialize!
ShopApp.routes.draw do
  get "/links/:id" => "pundit_shop/links#show"
  get "/links/:id/edit" => "pundit_shop/links#edit"
end

ann = Shop::User.new("ann")
Shop.session = Shop::Session.new(ann, ann, Shop::Link.new(ann))
app = Rack::MockRequest.new(ShopApp)
statuses = [app.get("/links/1/edit").status, app.get("/links/1").status]
Hallmark::Collectors.flush

stamps = Dir[File.join(ARGV.fetch(0), "tmp", "hallmark", "*.jsonl")]
set = stamps.empty? ? nil : Hallmark::StampSet.load(File.join(ARGV.fetch(0), "tmp", "hallmark"))
puts JSON.generate(
  active: Hallmark::Collectors.active?,
  mapped: Hallmark.configuration.mapping&.resources&.keys,
  statuses: statuses,
  stamps: set&.stamps&.map { |stamp| [stamp.entry_point, stamp.rule, stamp.decision] },
  unchecked: set&.unchecked&.map(&:entry_point)
)
