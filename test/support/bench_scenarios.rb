# frozen_string_literal: true

# Scenarios for bench/app.rb on the shop app (test/bench_app_test.rb): a
# request that authorizes one link, and a direct rule call.

ann = Shop::User.new("ann")
link = Shop::Link.new(ann)
session = Shop::Session.new(ann, ann, link)
app = Rack::MockRequest.new(Rails.application)

HotPath.scenario "GET /links/1/edit" do
  Shop.session = session
  app.get("/links/1/edit")
end

HotPath.scenario "LinkPolicy#edit? called directly" do
  PunditShop::LinkPolicy.new(PunditShop::Context.new(ann, ann), link).edit?
end
