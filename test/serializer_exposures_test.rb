# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require_relative "support/fixture_solver"

# Field exposures from REST serializers (phase 3 step 8): on the shop
# fixture's JSON API (test/fixtures/apps/shop/app/controllers/api), whose
# routes no test reached, so each entry point's exposures come from code;
# the report's section, SARIF and watch's events; and `from_code`. No Java.
class SerializerExposuresTest < Minitest::Test
  include Hallmark::Guard::DSL

  SHOP = File.join(HallmarkTestHelpers::FIXTURES, "apps", "shop")
  ACTIONS = %w[show preview index owner unknown export staff].freeze
  API = "app/controllers/api/links_controller.rb"
  LINK = "app/serializers/link_serializer.rb"

  def setup
    super
    Hallmark.configuration.root = SHOP
  end

  def mapping
    mapping = Hallmark::Mapping.new
    mapping.instance_eval do
      principal "User"
      tenant "User", membership: "TeamMembership", member: :user, roles: :role, self: :owner
      current_tenant :seller, controller: :current_seller
      platform_role :staff
      resource "Link", tenant: :user, public_if: :published?, permits: :collaborator_for?
      resource "User", kind: :profile
      %i[owner admin marketing].each do |name|
        grant name, :read, "Link"
        term "user.role_#{name}_for?(seller)", role(name, tenant: :current)
        term "user.role_#{name}_for?(record.user)", role(name, tenant: :record)
      end
      term "user.feature_enabled?(:previews)", none
      field_policy "Link", :revenue, role(:owner, tenant: :record) | role(:admin, tenant: :record)
      restrict("staff never see buyers") { deny role: :staff, op: :read, resource: "Link", fields: %i[buyer_emails] }
    end
    mapping
  end

  # Staff's update rule is reached by a POST, so it writes.
  def routes
    ACTIONS.map do |action|
      Hallmark::Route.new(entry_point: "Api::LinksController##{action}", verb: action == "staff" ? "POST" : "GET")
    end
  end

  # The index's list, from one listed record a test stamped.
  def list_stamp
    Hallmark::Stamp.new(policy: "LinkPolicy", rule: "Scope#resolve", resource: "Link", class_level: false,
                        entry_point: "Api::LinksController#index", enforced: false, decision: "allow", logged_in: true,
                        roles: [], record_roles: ["admin"], current_roles: ["admin"], in_current_tenant: true,
                        public_record: false, permitted: false, list: true)
  end

  def inference(stamps = [list_stamp], map = mapping)
    Hallmark::Inference.new(map.validate!, Hallmark::StampSet.new(stamps, [], routes),
                            extractor: Hallmark::Extractor.load(map, SHOP))
  end

  def fields(found = inference)
    found.exposures.select(&:shown_by).to_h { |each| ["#{each.action} #{each.field}", each] }
  end

  def base(found, entry_point)
    found.exposures.find { |each| each.action == entry_point && !each.field && !each.list? }
  end

  # Only fields with a field policy (revenue) or that a restriction names
  # (buyer_emails) become exposures, at each entry point that shows them.
  def test_only_policed_fields_become_exposures
    expected = %w[export index preview show staff].flat_map do |action|
      ["Api::LinksController##{action} buyer_emails", "Api::LinksController##{action} revenue"]
    end

    assert_equal expected, fields.keys.sort
  end

  # The entry point's own guard AND the field's condition, by its lower
  # bound; the check is step 4's field check.
  def test_guard_is_the_entry_points_and_the_fields
    found = inference
    show = fields(found).fetch("Api::LinksController#show revenue")

    assert_equal Hallmark::Guard.conjoin(base(found, "Api::LinksController#show").guard,
                                         role(:admin, tenant: :record)), show.guard
    assert_equal "safe_Api_LinksController_show_read_Link_revenue", show.check_name
    assert_equal [:read, "Link.revenue"], [show.op, show.target]
    assert_equal ["LinkPolicy#show?"], show.rules
  end

  # Two renderings at one entry point (each side of a branch) are ORed,
  # each with its branch's condition.
  def test_two_renderings_are_ored
    found = inference
    preview = fields(found).fetch("Api::LinksController#preview revenue")
    guard = base(found, "Api::LinksController#preview").guard
    admin = role(:admin, tenant: :record)

    assert_equal Hallmark::Guard.disjoin(Hallmark::Guard.conjoin(guard, in_current_tenant & admin),
                                         Hallmark::Guard.conjoin(guard, ~in_current_tenant & admin)), preview.guard
  end

  # A collection rests on the entry point's list.
  def test_a_collection_uses_the_list
    found = inference
    list = found.exposures.find(&:list?)

    assert_equal Hallmark::Guard.conjoin(list.guard, role(:admin, tenant: :record)),
                 fields(found).fetch("Api::LinksController#index revenue").guard
  end

  # A record exposure of every op at the entry point is ANDed in: staff's
  # rule writes, and its render shows the field to whoever passed it.
  def test_every_op_is_anded
    found = inference
    staff = base(found, "Api::LinksController#staff")

    assert_equal :write, staff.op
    assert_equal staff.guard, fields(found).fetch("Api::LinksController#staff buyer_emails").guard
  end

  # Where a fix goes first: the field, then the render, then the rule.
  def test_locations_and_shown_by
    show = fields.fetch("Api::LinksController#show revenue")

    assert_equal ["#{LINK}:7", "#{API}:12", "#{API}:11"], show.locations.first(3)
    assert_equal "LinkSerializer#revenue (#{LINK}:7)", show.shown_by
    assert_match(/shown by LinkSerializer \(#{LINK}:7\) where role\(:admin, tenant: :record\)/o, show.basis)
  end

  # What is not checked, noted: an unknown serializer, a record the entry
  # point does not authorize, a nested record, a viewer-reading field
  # with no policy.
  def test_notes_what_is_not_checked
    notes = inference.serializer_notes

    assert_equal ["Api::LinksController#unknown: serializer: serializer_for(@link) (#{API}:36)"], notes.unknown
    assert_equal ["Api::LinksController#owner: @link.user shown by UserSerializer (#{API}:31)"], notes.unauthorized
    assert_includes notes.nested, "Api::LinksController#show: LinkSerializer#user (#{LINK}:16) shows User"
    assert(notes.unpoliced.any? { |line| line.start_with?("LinkSerializer#stats") })
    refute(notes.unpoliced.any? { |line| line.start_with?("LinkSerializer#draft") })
    assert_equal 0, notes.unrendered
  end

  # A field whose condition leaves nothing certain is noted, not checked;
  # one an option it is not passed rules out is not shown at all.
  def test_an_unread_condition_is_noted
    map = mapping
    map.field_policy "Link", :margin, role(:owner, tenant: :record)
    map.field_policy "Link", :notes, role(:owner, tenant: :record)
    found = inference([list_stamp], map)
    keys = fields(found).keys

    refute(keys.any? { |key| key.end_with?(" margin") })
    assert_includes found.serializer_notes.unread, "Api::LinksController#show: LinkSerializer#margin (#{LINK}:18)"
    assert_equal ["Api::LinksController#preview notes"], keys.grep(/ notes\z/)
    refute(found.serializer_notes.unread.any? { |line| line.include?("#notes") })
  end

  # The same exposures digest the same with serializers in the app or not.
  def test_digests_are_unchanged
    Dir.mktmpdir("hallmark-shop") do |copy|
      FileUtils.cp_r("#{SHOP}/.", copy)
      FileUtils.rm_r(File.join(copy, "app", "serializers"))
      Hallmark.configuration.root = copy
      without = Hallmark::Inference.new(mapping.validate!, Hallmark::StampSet.new([list_stamp], [], routes),
                                        extractor: Hallmark::Extractor.load(mapping, copy))
      Hallmark.configuration.root = SHOP
      with = inference
      digests = ->(found) { found.exposures.reject(&:shown_by).to_h { [_1.check_name, _1.digest(mapping)] } }

      assert_equal digests.call(without), digests.call(with)
      refute_empty digests.call(with)
    end
  end

  def build_analysis(verdicts = {})
    found = inference
    analysis = Hallmark::Analysis.new("REST")
    analysis.instance_variable_set(:@mapping, mapping.validate!)
    analysis.instance_variable_set(:@inference, found)
    found.exposures.each { |exposure| analysis.add(exposure) }
    [analysis, analysis.run(solver: FixtureSolver.new(verdicts))]
  end

  REVENUE = "safe_Api_LinksController_show_read_Link_revenue"

  # The FAIL line and SARIF name the serializer field; the hint points at
  # its condition; the section lists what was not checked.
  def test_report_and_sarif_name_the_field
    _, report = build_analysis(REVENUE => :counterexample)
    text = report.to_s

    assert_includes text, "FAIL  Api::LinksController#show (read Link.revenue, shown by LinkSerializer#revenue " \
                          "(#{LINK}:7))"
    assert_includes text, "REST serializers (coverage, not findings):"
    assert_includes text, "  Renderings whose serializer Hallmark cannot tell (1):"
    sarif = Hallmark::Sarif.new([report]).to_h.dig("runs", 0, "results", 0)

    assert_match(/shown by LinkSerializer#revenue/, sarif.dig("message", "text"))
    assert_equal "#{LINK}:7", sarif.dig("locations", 0, "physicalLocation", "artifactLocation", "uri") +
                              ":#{sarif.dig("locations", 0, "physicalLocation", "region", "startLine")}"
  end

  def test_watch_events_carry_shown_by
    _, report = build_analysis(REVENUE => :counterexample)
    event = Hallmark::Watch::Event.finding(report.findings.fetch(0), nil)

    assert_equal "LinkSerializer#revenue (#{LINK}:7)", event.to_h["shown_by"]
  end

  # Each list prints its first 12 and counts the rest.
  def test_the_section_caps_its_lists
    analysis, report = build_analysis
    notes = analysis.inference.serializer_notes
    notes.nested.concat(Array.new(14) { |at| "E#{at}: S#f (x.rb:1) shows User" })
    lines = report.serializer_lines

    assert_includes lines, "    and #{notes.nested.size - 12} more"
  end

  # `from_code`: entry points from config/routes.rb, no stamps.
  def test_from_code_reads_routes
    Dir.mktmpdir("hallmark-from-code") do |root|
      FileUtils.cp_r("#{SHOP}/.", root)
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config", "routes.rb"), <<~RUBY)
        Rails.application.routes.draw do
          namespace :api do
            resources :links, only: :show
          end
        end
      RUBY
      map = mapping
      analysis = Hallmark::Analysis.build("From code", mapping: map) { from_code root }

      assert_equal ["Api::LinksController#show"], analysis.exposures.map(&:action).uniq
      assert_equal %w[buyer_emails revenue], analysis.exposures.filter_map(&:field).sort
    end
  end

  # With stamps, routes come from the stamps as before.
  def test_stamps_still_read_recorded_routes
    analysis = Hallmark::Analysis.build("Stamps", mapping: mapping) do
      stamps Hallmark::StampSet.new([], [],
                                    [Hallmark::Route.new(entry_point: "Api::LinksController#show", verb: "GET")])
    end

    assert_equal ["Api::LinksController#show"], analysis.exposures.map(&:action).uniq
  end
end
