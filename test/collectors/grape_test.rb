# frozen_string_literal: true

require "test_helper"
require "grape"
require "rack/mock"
require "hallmark/collectors/grape"
require_relative "shop_people"

# The Grape hook names the entry point for decisions an endpoint makes, as
# the static reader names it.
class GrapeCollectorTest < Minitest::Test
  include ShopPeople

  # A REST API over the shop, GitLab-shaped: a prefix, a path version, and
  # an authorize! helper.
  class ShopAPI < Grape::API
    prefix :api
    version "v4", using: :path
    format :json

    helpers do
      def authorize!(ability, subject)
        error!("403 Forbidden", 403) unless DpShop::LinkPolicy.new(Shop.session.user, subject).allowed?(ability)
      end
    end

    resource :links do
      route_param :id do
        put do
          authorize! :update_link, Shop.session.link
          { ok: true }
        end
      end
    end
  end

  def test_names_the_entry_point_of_each_decision
    set = collect(current_tenant: -> { Shop.session&.seller }) do
      Shop.session = Shop::Session.new(@ada, @ann, @ann_link)
      status = Rack::MockRequest.new(ShopAPI).put("/api/v4/links/1").status

      assert_equal 200, status
    ensure
      Shop.session = nil
    end

    assert_equal ["PUT /links/:id"], set.stamps.map(&:entry_point).uniq
  end

  def test_drops_the_prefix_version_and_format
    assert_equal "/projects/:id/pipeline_schedules",
                 Hallmark::Collectors::GrapeHook.path("/api/:version/projects/:id/pipeline_schedules", "api", "v4")
    assert_equal "/status", Hallmark::Collectors::GrapeHook.path("/status", nil, nil)
  end
end
