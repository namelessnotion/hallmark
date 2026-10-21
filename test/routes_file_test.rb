# frozen_string_literal: true

require "test_helper"

# Rails routes read from the board fixture's config/routes.rb, never loading
# it (`Extractor::RoutesFile`). No Java.
class RoutesFileTest < Minitest::Test
  ROOT = File.join(HallmarkTestHelpers::FIXTURES, "apps", "board")

  def routes = Hallmark::Extractor::RoutesFile.new(ROOT).routes

  def verbs(entry_point) = routes.select { |route| route.entry_point == entry_point }.map(&:verb)

  # `module: :api` camelizes with the app's acronym.
  def test_reads_resources_with_only_and_except
    tags = %w[index create new show update destroy].to_h { |action| [action, verbs("API::TagsController##{action}")] }

    assert_equal({ "index" => %w[GET], "create" => %w[POST], "new" => [], "show" => %w[GET],
                   "update" => %w[PATCH PUT], "destroy" => %w[DELETE] }, tags)
    assert_equal %w[GET], verbs("EventsController#index")
    assert_equal %w[PATCH PUT], verbs("EventsController#update")
    assert_empty verbs("EventsController#destroy")
  end

  # A bare name in a resource's block belongs to its controller; `to:`
  # names another action; a redirect is skipped.
  def test_reads_routes_inside_a_resource
    found = routes.to_h { |route| [[route.entry_point, route.verb], route.path] }

    expected = { %w[EventsController#ledger GET] => "/events/:event_id/ledger",
                 %w[EventsController#toggle_pinned POST] => "/events/:event_id/toggle_pinned",
                 %w[EventsController#new_payout GET] => "/events/:event_id/payouts/new",
                 %w[EventsController#archive POST] => "/events/:id/archive",
                 %w[EventsController#mine GET] => "/events/mine",
                 %w[Payroll::PayeesController#create POST] => "/events/:event_id/payees" }

    assert_equal expected, found.slice(*expected.keys)
    assert_empty verbs("EventsController#edit")
  end

  def test_reads_namespaces_scopes_and_controller_blocks
    assert_equal %w[GET], verbs("Admin::EventsController#index")
    assert_equal %w[GET], verbs("Admin::DashboardController#stats")
    assert_equal %w[GET], verbs("PagesController#terms")
    assert_equal %w[GET], verbs("PagesController#home")
    assert_equal %w[GET], verbs("PagesController#about")
    assert_equal %w[GET], verbs("PhotosController#search")
  end

  # A singular resource's controller is plural; `match` takes `via:`
  # (any verb for :all); concerns and drawn files are read; a mounted
  # engine and routes built in a loop are not.
  def test_reads_singular_resources_match_concerns_and_drawn_files
    assert_equal %w[GET], verbs("InboxesController#show")
    assert_equal %w[GET HEAD], verbs("PagesController#status")
    assert_equal [""], verbs("HooksController#receive")
    assert_equal %w[POST], verbs("CommentsController#create")
    assert_equal %w[GET], verbs("PagesController#extra")
    assert_equal 31, routes.size
  end

  def test_an_app_without_routes_has_none
    assert_empty Hallmark::Extractor::RoutesFile.new(File.join(HallmarkTestHelpers::FIXTURES, "apps", "shop")).routes
  end
end
