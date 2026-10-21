# frozen_string_literal: true

require "test_helper"
require_relative "support/fixture_solver"
require "open3"
require "rbconfig"

# SARIF 2.1.0 output (phase 2 step 5), from reports built on FixtureSolver
# and the extractor fixtures; no Java.
class SarifTest < Minitest::Test
  include Hallmark::Guard::DSL

  FIXTURES = HallmarkTestHelpers::FIXTURES
  UPDATE = "safe_LinksController_update_write_Link"

  def storefront(locations)
    analysis = Hallmark::Analysis.build("Storefront") do
      map do
        tenant "User", membership: "TeamMembership", self: :owner
        current_tenant :seller
        resource "Link", tenant: :user
      end
    end
    analysis.add_exposure(action: "LinksController#update", op: :write, resource: "Link",
                          guard: role(:admin, tenant: :current), locations: locations)
    analysis.validate!
  end

  def sarif(reports, fallback: "config/hallmark.rb") = Hallmark::Sarif.new(reports, fallback: fallback).to_h
  def results(log) = log.fetch("runs").fetch(0).fetch("results")
  def place(result, key = "locations") = result.fetch(key).map { |loc| where(loc) }

  def where(location)
    physical = location.fetch("physicalLocation")
    [physical.dig("artifactLocation", "uri"), physical.dig("region", "startLine")]
  end

  def test_a_counterexample_points_at_the_entry_point_then_the_rule
    report = storefront(["app/controllers/links_controller.rb:12", "app/policies/link_policy.rb:9"])
             .run(solver: FixtureSolver.new(UPDATE => :counterexample))
    log = sarif([report])
    result = results(log).fetch(0)

    assert_equal "2.1.0", log.fetch("version")
    assert_equal "hallmark/counterexample", result.fetch("ruleId")
    assert_match(/\ALinksController#update \(write Link\): a signed-in User/, result.dig("message", "text"))
    assert_equal [["app/controllers/links_controller.rb", 12]], place(result)
    assert_equal [["app/policies/link_policy.rb", 9]], place(result, "relatedLocations")
  end

  def test_a_field_counterexample_names_the_field_and_what_was_intended
    analysis = Hallmark::Analysis.build("Storefront") do
      map do
        tenant "User", membership: "TeamMembership", self: :owner
        current_tenant :seller
        resource "Link", tenant: :user, public_if: :published?
        field_policy "Link", :price, public_record
      end
      reads "LinksController#show", "Link", field: :price, guard: role(:admin, tenant: :current)
    end
    report = analysis.run(solver: FixtureSolver.new("safe_LinksController_show_read_Link_price" => :counterexample))
    text = results(sarif([report])).fetch(0).dig("message", "text")

    assert_match(/\ALinksController#show \(read Link.price\): .* can read the price of a Link/, text)
    assert_includes text, "Intended: field policy for Link.price: public_record."
  end

  def test_a_result_with_no_source_line_points_at_the_mapping_file
    report = storefront([]).run(solver: FixtureSolver.new(UPDATE => :counterexample))

    assert_equal [["config/hallmark.rb", nil]], place(results(sarif([report])).fetch(0))
  end

  # The fingerprint names the check, not the run, so it holds across runs.
  def test_fingerprints_are_stable
    prints = 2.times.map do
      report = storefront([]).run(solver: FixtureSolver.new(UPDATE => :counterexample))
      results(sarif([report])).fetch(0).dig("partialFingerprints", "hallmark/v1")
    end

    assert_equal 1, prints.uniq.size
  end

  def test_a_clean_report_has_no_results_and_lists_the_rules
    log = sarif([storefront([]).run(solver: FixtureSolver.new)])

    assert_empty results(log)
    ids = log.dig("runs", 0, "tool", "driver", "rules").map { |rule| rule.fetch("id") }

    assert_equal %w[hallmark/counterexample hallmark/unchecked hallmark/drift hallmark/D3 hallmark/D4 hallmark/G4
                    hallmark/G5], ids
  end

  # An unchecked entry point points at its action, read from the controller.
  def test_an_unchecked_entry_point_points_at_its_action
    Hallmark.configuration.root = File.join(FIXTURES, "apps", "shop")
    analysis = Hallmark::Analysis.build("Shop") do
      map { resource "Link" }
      stamps Hallmark::StampSet.new([], [Hallmark::Unchecked.new(entry_point: "Admin::ReportsController#index")])
    end
    result = results(sarif([analysis.run(solver: FixtureSolver.new)])).find do |each|
      each.fetch("ruleId") == "hallmark/unchecked"
    end

    assert_equal [["app/controllers/admin/reports_controller.rb", 6]], place(result)
  end

  # DeclarativePolicy hazards point at their condition or rule.
  def test_policy_dsl_hazards_point_at_their_code
    Hallmark.configuration.root = File.join(FIXTURES, "apps", "declarative_buggy")
    analysis = Hallmark::Analysis.build("Declarative") do
      map do
        tenant "Project", membership: "ProjectMember", roles: :access_level
        resource "Project", tenant: :itself
        rule "ProjectPolicy", :star_project, op: :write
        rule "ProjectPolicy", :update_schedule, op: :write
      end
      stamps Hallmark::StampSet.new
    end
    hazards = results(sarif([analysis.run(solver: FixtureSolver.new)])).reject do |each|
      each.fetch("ruleId") == "hallmark/counterexample"
    end

    assert_equal({ "hallmark/D3" => [["app/policies/project_policy.rb", 14]],
                   "hallmark/D4" => [["app/policies/project_policy.rb", 30]] },
                 hazards.to_h { |each| [each.fetch("ruleId"), place(each)] })
  end

  def test_check_writes_sarif_beside_the_report
    Dir.mktmpdir("hallmark-sarif") do |dir|
      out = File.join(dir, "hallmark.sarif")
      _output, _error, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin", "hallmark"), "check", "--sarif",
                                               out, File.join(ROOT, "examples", "storefront", "hallmark.rb"))

      assert_equal 1, status.exitstatus
      log = JSON.parse(File.read(out))

      assert_equal [["hallmark.rb", nil]], place(results(log).fetch(0))
    end
  end
end
