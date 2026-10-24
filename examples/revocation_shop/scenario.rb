# frozen_string_literal: true

# Boots the revocation shop (or `fixed/` with `fixed`) as a Rails app with
# Hallmark's collectors in test mode, on SQLite in memory and a memory
# cache, and serves one story: a seller's admin updates a product, the
# membership is downgraded to marketing (or, with `soft_delete`, ended by
# its `deleted_at`), and the same user updates it again. Stamps go to the
# app's tmp/hallmark (HALLMARK_STAMPS to put them elsewhere), as run
# "scenario" (or "softdelete"; HALLMARK_RUN to name another).
#
#   bundle exec ruby -Ilib examples/revocation_shop/scenario.rb [fixed] [soft_delete]
#
# Prints the two update statuses as JSON on its last line.

require "json"
require "logger"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "pundit"

fixed = ARGV.include?("fixed")
soft_delete = ARGV.include?("soft_delete")
root = fixed ? File.join(__dir__, "fixed") : __dir__
ENV["RAILS_ENV"] = "test"
ENV["HALLMARK_MODE"] ||= "test"
ENV["HALLMARK_RUN"] ||= soft_delete ? "softdelete" : "scenario"
ENV["DATABASE_URL"] = "sqlite3::memory:"
require "hallmark"

# The shop as a Rails application.
class RevocationShopApp < Rails::Application
  config.load_defaults 8.0
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "0" * 64
  config.hosts.clear
  config.cache_store = :memory_store
  config.active_record.maintain_test_schema = false
end
RevocationShopApp.config.root = root
RevocationShopApp.initialize!

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:users) { |t| t.string :name }
  create_table(:team_memberships) do |t|
    t.references :user
    t.references :seller
    t.string :role
    t.datetime :deleted_at
  end
  create_table(:links) do |t|
    t.references :user
    t.string :name
  end
end

seller = User.create!(name: "sam")
admin = User.create!(name: "ann")
membership = TeamMembership.create!(user: admin, seller: seller, role: "admin")
link = Link.create!(user: seller, name: "zine")
app = Rack::MockRequest.new(RevocationShopApp)
update = lambda do |name|
  app.request("PATCH", "/links/#{link.id}", params: { name: name },
                                            "HTTP_X_USER" => admin.id.to_s, "HTTP_X_SELLER" => seller.id.to_s).status
end

statuses = [update.call("zine, vol. 2")]
soft_delete ? membership.update!(deleted_at: Time.current) : membership.update!(role: "marketing")
statuses << update.call("zine, vol. 3")
Hallmark::Collectors.flush
puts JSON.generate(statuses: statuses)
