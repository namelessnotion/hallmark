# frozen_string_literal: true

require "test_helper"
require_relative "shop_people"

# Threat 10: entry points that finish without any authorization call.
class ControllerCollectorTest < Minitest::Test
  include ShopPeople

  SHOW = "PunditShop::LinksController#show"
  PREVIEW = "PunditShop::LinksController#preview"
  ARCHIVE = "PunditShop::LinksController#archive"

  def test_flags_an_entry_point_that_never_authorized
    set = collect { assert_equal 200, Shop.request(PunditShop::LinksController, :show, user: @ann, seller: @ann) }

    assert_equal [Hallmark::Unchecked.new(entry_point: SHOW, status: 200, verb: "GET")], set.unchecked
  end

  # The collectors install after Rails eager loads the controllers, so the
  # hook must still run before a controller's own filters.
  def test_an_authorization_in_a_filter_belongs_to_the_entry_point
    set = collect do
      assert_equal 200, Shop.request(PunditShop::LinksController, :rename, user: @ann, seller: @ann, link: @ann_link)
    end

    assert_empty set.unchecked
    assert_equal ["PunditShop::LinksController#rename"], set.stamps.map(&:entry_point)
  end

  def test_records_the_status_and_verb_in_the_jsonl
    lines = nil
    collect do
      Shop.request(PunditShop::LinksController, :archive, user: @ann, seller: @ann, verb: "HEAD")
      Hallmark::Collectors.flush
      lines = File.readlines(Hallmark::Collectors.store&.path || flunk, chomp: true)
    end

    expected = { "type" => "unchecked", "entry_point" => ARCHIVE, "status" => 302, "verb" => "HEAD" }
    assert_equal([expected], lines.map { |line| JSON.parse(line) })
  end

  def test_does_not_flag_authorized_halted_or_failed_requests
    set = collect do
      Shop.request(PunditShop::LinksController, :edit, user: @ann, seller: @ann, link: @ann_link)
      Shop.request(PunditShop::LinksController, :edit, user: @sam, seller: @ann, link: @ann_link) # denied
      assert_equal 302, Shop.request(PunditShop::LinksController, :index, user: @ann) # a filter redirects
      assert_equal 404, Shop.request(PunditShop::LinksController, :missing, user: @ann, seller: @ann)
    end

    assert_empty set.unchecked
  end

  def test_unchecked_entry_points_fail_the_report_unless_allowed
    set = collect { Shop.request(PunditShop::LinksController, :show, user: @ann, seller: @ann) }
    analysis = Hallmark::Analysis.build("Shop", mapping: Shop.map(Hallmark::Mapping.new)) { stamps set }
    report = analysis.run(solver: nil)

    refute_predicate report, :clean?
    assert_includes report.to_s, "FAIL  #{SHOW} finished without an authorization call"

    allowed = Shop.map(Hallmark::Mapping.new)
    allowed.allow_unchecked SHOW
    assert_predicate Hallmark::Analysis.build("Shop", mapping: allowed) { stamps set }.run(solver: nil), :clean?
  end

  def analyze(set) = Hallmark::Analysis.build("Shop", mapping: Shop.map(Hallmark::Mapping.new)) { stamps set }

  # A GET the action body redirected before authorizing (the link is
  # missing), while another request to the same action authorized: the
  # redirect served no data, so it is coverage, not a failure.
  def redirect_then_authorize
    collect do
      assert_equal 302, Shop.request(PunditShop::LinksController, :preview, user: @ann, seller: @ann)
      assert_equal 200, Shop.request(PunditShop::LinksController, :preview, user: @ann, seller: @ann, link: @ann_link)
    end
  end

  def test_a_get_redirect_at_an_entry_point_that_authorized_elsewhere_is_coverage
    inference = analyze(redirect_then_authorize).inference || flunk

    assert_empty inference.unchecked
    assert_equal [PREVIEW], inference.coverage.redirected
  end

  def test_the_report_lists_the_excused_redirect_under_coverage
    analysis = analyze(redirect_then_authorize)
    names = analysis.exposures.map(&:check_name)
    report = Hallmark::Report.new(analysis, Hallmark::Receipt.unknown(names, "not solved in this test"))

    refute_predicate report, :failed?
    refute_includes report.to_s, "finished without an authorization call"
    assert_includes report.to_s, "Entry points that redirected a GET without an authorization call " \
                                 "(authorized in other requests): #{PREVIEW}"
  end

  # A denied sibling counts too: the entry point reached a rule.
  def test_a_denied_sibling_also_excuses_the_redirect
    set = collect do
      Shop.request(PunditShop::LinksController, :preview, user: @sam, seller: @sam)
      assert_equal 403, Shop.request(PunditShop::LinksController, :preview, user: @sam, seller: @ann, link: @ann_link)
    end

    assert_predicate analyze(set).run(solver: nil), :clean?
  end

  # An action that only ever redirects, as a signed-URL download does, may
  # hand out another user's record: it fails.
  def test_a_get_redirect_that_never_authorizes_fails
    set = collect { assert_equal 302, Shop.request(PunditShop::LinksController, :archive, user: @ann, seller: @ann) }
    report = analyze(set).run(solver: nil)

    assert_equal [ARCHIVE], report.unchecked
    assert_includes report.to_s, "FAIL  #{ARCHIVE} finished without an authorization call"
  end

  # A write that redirects has already acted, so it fails even when another
  # request to the entry point authorized.
  def test_a_write_that_redirects_fails
    set = collect do
      assert_equal 302, Shop.request(PunditShop::LinksController, :preview, user: @ann, seller: @ann, verb: "PATCH")
      Shop.request(PunditShop::LinksController, :preview, user: @ann, seller: @ann, link: @ann_link)
    end
    inference = analyze(set).inference || flunk

    assert_equal [PREVIEW], inference.unchecked
    assert_empty inference.coverage.redirected
  end

  def test_a_success_without_authorization_fails_even_beside_an_authorized_request
    set = collect do
      Shop.request(PunditShop::LinksController, :show, user: @ann, seller: @ann)
      Hallmark::Collectors.decision(policy: PunditShop::LinkPolicy.new(PunditShop::Context.new(@ann, @ann), @ann_link),
                                    rule: :edit?, record: @ann_link, allowed: true, enforced: true, entry_point: SHOW)
    end
    inference = analyze(set).inference || flunk

    assert_equal [SHOW], inference.unchecked
    assert_empty inference.coverage.redirected
  end
end
