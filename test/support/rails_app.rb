# frozen_string_literal: true

# Boots a minimal Rails app rooted at ARGV[0] (which holds config/hallmark.rb),
# serves two requests and prints what the collectors did as JSON. Run by
# test/railtie_test.rb in a child process, so Rails state stays out of the
# other tests.

require "json"
require_relative "shop_app"

# Serves `requests` ([verb, path, session]) with each session in place.
def serve(app, requests)
  requests.map do |verb, path, session|
    Shop.session = session
    app.request(verb, path).status
  end
end

ann = Shop::User.new("ann")
app = Rack::MockRequest.new(ShopApp)
own = Shop::Session.new(ann, ann, Shop::Link.new(ann))
statuses =
  case ENV.fetch("SHOP_SCENARIO", nil)
  # What test/watch_end_to_end_test.rb's CI run sees: a seller on its own link.
  when "watch_ci" then serve(app, [["GET", "/links/1/edit", own], ["PATCH", "/links/1", own]])
  # Live traffic: ann's admin, acting for ann, on another seller's link (M2).
  # The users and the link have ids, so hashed ids name them.
  when "watch_live"
    bob = Shop::User.new("bob")
    carol = Shop::User.new("carol")
    link = Shop::Link.new(carol)
    { bob => 2, carol => 3, link => 7 }.each { |object, id| object.define_singleton_method(:id) { id } }
    Shop.memberships[[bob, ann]] = ["admin"]
    cross = Shop::Session.new(bob, ann, link)
    serve(app, [["GET", "/links/7/edit", cross], ["PATCH", "/links/7", cross]])
  else serve(app, [["GET", "/links/1/edit", own], ["GET", "/links/1", own]])
  end
Hallmark::Collectors.flush

stamps = Dir[File.join(ARGV.fetch(0), "tmp", "hallmark", "*.jsonl")]
set = stamps.empty? ? nil : Hallmark::StampSet.load(File.join(ARGV.fetch(0), "tmp", "hallmark"))
puts JSON.generate(
  active: Hallmark::Collectors.active?,
  mapped: Hallmark.configuration.mapping&.resources&.keys,
  statuses: statuses,
  stamps: set&.stamps&.map { |stamp| [stamp.entry_point, stamp.rule, stamp.decision] },
  unchecked: set&.unchecked&.map(&:entry_point),
  routes_before_exit: set&.routes&.map(&:entry_point),
  files: stamps.map { |file| File.basename(file).sub(/-\d+\.jsonl\z/, "") }.uniq
)
