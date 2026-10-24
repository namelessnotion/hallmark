# frozen_string_literal: true

require "test_helper"
require "stringio"
require "hallmark/rspec"
require_relative "support/fixture_solver"

# Stale access after revocation (phase 3 step 9): allow-stamps the
# revocations collector marked, set aside by inference and judged against
# what else the rule allows, in the report, SARIF, baselines, watch and the
# matchers. Hand-built stamps on the shop fixture's policy code; no Java.
class StaleAccessTest < Minitest::Test
  include Hallmark::Guard::DSL

  ROOT = File.join(HallmarkTestHelpers::FIXTURES, "apps", "shop")

  def setup
    super
    Hallmark.configuration.root = ROOT
  end

  def stamp(rule: "update?", entry_point: "LinksController#update", decision: "allow", **facts)
    defaults = {
      policy: "LinkPolicy", resource: "Link", class_level: false, enforced: true, logged_in: true,
      in_current_tenant: true, permitted: false, roles: [], record_roles: [], current_roles: []
    }
    Hallmark::Stamp.new(**defaults, entry_point: entry_point, rule: rule, decision: decision, **facts)
  end

  def as_admin = { current_roles: ["admin"], record_roles: ["admin"] }
  def as_marketer = { current_roles: ["marketing"], record_roles: ["marketing"] }
  def demoted(**facts) = stamp(**as_marketer, after_revocation: ["admin"], **facts)

  def analysis(stamps, root: ROOT, &extra)
    Hallmark::Analysis.build("Shop") do
      map do
        tenant "User", membership: "TeamMembership", self: :owner, roles_in: :team_roles_for
        current_tenant :seller
        platform_role :staff
        resource "Link", tenant: :user, permits: :collaborator_for?
        grant :owner, :write, "Link"
        grant :admin, :write, "Link"
        grant :marketing, :read, "Link"
        term "user.role_owner_for?(seller)", role(:owner, tenant: :current)
        term "user.role_admin_for?(seller)", role(:admin, tenant: :current)
        term "user.role_marketing_for?(seller)", role(:marketing, tenant: :current)
        instance_eval(&extra) if extra
      end
      stamps Hallmark::StampSet.new(stamps), root: root
    end
  end

  def inference(stamps, ...) = analysis(stamps, ...).inference
  def stale(stamps, ...) = inference(stamps, ...).stale_access

  def test_a_marked_allow_feeds_no_guard_drift_or_coverage_region
    plain = inference([stamp(**as_admin)])
    marked = inference([stamp(**as_admin), demoted])

    assert_empty marked.drift
    assert_equal(plain.units.map { |unit| unit.guard.to_s }, marked.units.map { |unit| unit.guard.to_s })
    assert_equal plain.coverage.gaps, marked.coverage.gaps
    assert_equal 1, marked.stale_access.size
  end

  # Without the mark, the downgraded admin's allow is drift: outside the
  # rule's upper bound.
  def test_unmarked_the_same_allow_is_drift
    assert_equal ["LinkPolicy#update?"], inference([stamp(**as_admin), stamp(**as_marketer)]).drift.map(&:rule)
  end

  def test_a_marked_allow_still_reaches_its_entry_point
    routes = [Hallmark::Route.new(entry_point: "LinksController#archive", verb: "PATCH", path: "/links/:id/archive")]
    set = Hallmark::StampSet.new([demoted(rule: "archive?", entry_point: "LinksController#archive")], [], routes)
    found = Hallmark::Inference.new(analysis([]).mapping, set, extractor: Hallmark::Extractor.load(analysis([]).mapping))

    assert_empty found.unchecked
    assert_empty found.coverage.routes_unchecked + found.coverage.routes_unread + found.coverage.routes_unresolved
    refute_includes found.exposures.map(&:action), "LinksController#archive"
  end

  def test_judged_stale_when_nothing_else_allows_it
    item = stale([stamp(**as_admin), demoted]).fetch(0)

    assert_equal ["LinkPolicy#update?", "Link", ["admin"], "the current tenant", "app/policies/link_policy.rb:14"],
                 [item.rule, item.resource, item.revoked, item.tenant, item.location]
    assert_equal "logged_in & ~permitted & in_current_tenant & record_roles=[marketing] & current_roles=[marketing]",
                 item.facts
    assert_equal ["LinksController#update"], item.seen
    assert_equal "LinkPolicy#update?|Link|admin|#{item.facts}", item.key
  end

  # index? lets marketing in: the code's lower bound explains the allow.
  def test_explained_by_the_rules_code
    found = inference([demoted(rule: "index?", entry_point: "LinksController#index")])

    assert_empty found.stale_access
    assert_equal ["LinkPolicy#index? (Link) at LinksController#index, after losing admin"],
                 found.coverage.stale_explained
  end

  def test_explained_by_another_allow_stamp_or_a_public_record
    others = [stamp(rule: "custom?", **as_marketer), demoted(rule: "custom?")]

    assert_empty stale(others) { rule "LinkPolicy", :custom?, op: :write }

    anonymous = { logged_in: false, public_record: true, current_roles: nil, record_roles: [] }
    public_records = [stamp(rule: "shared?", **anonymous), demoted(rule: "shared?", public_record: true)]

    assert_empty(stale(public_records) do
      rule "LinkPolicy", :shared?, op: :read
      @resources.delete("Link")
      resource "Link", tenant: :user, permits: :collaborator_for?, public_if: :published?
    end)
  end

  # update? asks about explicit permission first; a stamp that does not say
  # leaves the verdict unknown. A rule with no other allow and no code has
  # no guard at all.
  def test_not_judged_when_unknown_or_unguarded
    unknown = inference([demoted(permitted: nil)])
    unguarded = inference([demoted(rule: "unwritten?")]) { rule "LinkPolicy", :unwritten?, op: :write }

    assert_empty unknown.stale_access
    assert_equal ["LinkPolicy#update? (Link) at LinksController#update, after losing admin"],
                 unknown.coverage.stale_unjudged
    assert_empty unguarded.stale_access
    assert_equal 1, unguarded.coverage.stale_unjudged.size
  end

  def test_equal_stamps_collapse_into_one_listing_where_each_was_seen
    found = stale([stamp(**as_admin), demoted, demoted(entry_point: "Api::LinksController#update")])

    assert_equal 1, found.size
    assert_equal ["Api::LinksController#update", "LinksController#update"], found.fetch(0).seen
  end

  # Coverage's own `stale` list (stamps recorded before their resource's
  # facts were mapped) keeps its meaning.
  def test_coverage_stale_keeps_its_meaning
    owned = proc do
      @resources.delete("Link")
      resource "Link", tenant: :user, permits: :collaborator_for?, owner: :creator
    end

    assert_empty inference([stamp(**as_admin, owner: false), demoted(owner: nil)], &owned).coverage.stale
    assert_equal ["LinkPolicy#update?"], inference([stamp(**as_admin, owner: nil)], &owned).coverage.stale
  end

  def test_digests_are_unchanged_with_marked_stamps
    plain = analysis([stamp(**as_admin)])
    marked = analysis([stamp(**as_admin), demoted, demoted(rule: "index?", entry_point: "LinksController#index")])

    digests = ->(each) { each.exposures.to_h { |exposure| [exposure.check_name, exposure.digest(each.mapping)] } }

    assert_equal digests.call(plain), digests.call(marked)
  end

  def report(stamps) = analysis(stamps).run(solver: FixtureSolver.new)

  def test_stale_access_fails_the_report_in_its_own_section
    found = report([stamp(**as_admin), demoted])
    text = found.to_s

    assert_predicate found, :failed?
    assert_equal 1, found.exit_code
    assert_includes text,
                    "Stale access after revocation (allows after the user lost a role that nothing else explains):"
    assert_includes text, "STALE LinkPolicy#update? (Link) at app/policies/link_policy.rb:14: allowed after the user " \
                          "lost admin in the current tenant, but neither its code nor any other allow-stamp allows " \
                          "logged_in & ~permitted"
    assert_includes text, "1 stale allow after revocation."
  end

  def test_sarif_reports_stale_access_at_the_rule
    results = JSON.parse(Hallmark::Sarif.new([report([stamp(**as_admin), demoted])]).to_json)
                  .dig("runs", 0, "results").select { |result| result["ruleId"] == "hallmark/stale" }

    assert_equal 1, results.size
    assert_equal({ "uri" => "app/policies/link_policy.rb" }, results[0].dig("locations", 0, "physicalLocation",
                                                                            "artifactLocation"))
    assert_match(%r{\ALinkPolicy#update\? \(Link\) at app/policies/link_policy.rb:14: allowed after},
                 results[0].dig("message", "text"))
    assert_equal 64, results[0].dig("partialFingerprints", "hallmark/v1").size
  end

  def test_a_baseline_lists_stale_keys_and_an_old_one_loads_without_them
    built = Hallmark::Baseline.build([report([stamp(**as_admin), demoted])], mapping_digest: "m", run: "ci")
    data = JSON.parse(built.to_json)

    assert_equal [stale([stamp(**as_admin), demoted]).fetch(0).key], data.fetch("stale")
    assert_includes data.fetch("lines").join, '"after_revocation":["admin"]'
    data.delete("stale")

    assert_empty Hallmark::Baseline.from_data(data).stale
  end

  def watch_once(baseline, lines)
    Dir.mktmpdir("hallmark-watch") do |dir|
      File.write(File.join(dir, "stamps-live-1.jsonl"), lines.map { "#{_1}\n" }.join)
      out = StringIO.new
      watch = Hallmark::Watch.new(mapping: analysis([]).mapping, baseline: baseline, out: out, err: StringIO.new,
                                  source: Hallmark::Watch::FileTail.new(dir, run: "live"), solver: FixtureSolver.new,
                                  mapping_digest: "m", extractor: Hallmark::Extractor.load(analysis([]).mapping))
      [watch.run(once: true), watch.events.select { |event| event.type == :stale }, out.string]
    end
  end

  def test_watch_reports_a_new_stale_key_once_and_a_known_one_never
    baseline = Hallmark::Baseline.build([report([stamp(**as_admin), demoted])], mapping_digest: "m", run: "ci")

    status, events, = watch_once(baseline, [demoted.to_json_line])

    assert_equal [0, []], [status, events]
    other = demoted(entry_point: "LinksController#update", current_roles: ["support"], record_roles: ["support"])
    status, events, out = watch_once(baseline, [other.to_json_line])

    assert_equal 1, status
    assert_equal 1, events.size
    assert_includes out, "1 new stale allow after revocation."
  end

  def matcher(stamps, rule = nil, solver: FixtureSolver.new)
    options = { mapping: analysis([]).mapping, stamps: Hallmark::StampSet.new(stamps), solver: solver }
    rule ? Hallmark::RSpec::HaveNoCounterexample.new(rule, **options) : Hallmark::RSpec::SatisfyCatalog.new(**options)
  end

  def test_a_matcher_fails_on_stale_access_in_the_rule_it_checks
    stamps = [stamp(**as_admin), demoted]
    check = matcher(stamps, :update?)

    refute check.matches?("LinkPolicy")
    assert_includes check.failure_message, "1 stale allow after revocation"
    assert_includes check.failure_message, "STALE LinkPolicy#update? (Link)"
    assert_includes check.failure_message, Hallmark::RSpec::Matcher::STALE_NOTE
    assert matcher(stamps, :edit?).matches?("LinkPolicy")

    solver = FixtureSolver.new("safe_LinkPolicy_update_write_Link" => :counterexample)

    refute matcher(stamps, :update?, solver: solver).does_not_match?("LinkPolicy")
  end
end
