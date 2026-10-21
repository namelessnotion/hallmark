# frozen_string_literal: true

require "test_helper"
require_relative "support/fixture_solver"

# The baseline `hallmark check --baseline` writes for `hallmark watch`
# (phase 3 step 3), and the exposure digests it records; no Java.
class BaselineTest < Minitest::Test
  include Hallmark::Guard::DSL

  UPDATE = "safe_LinksController_update_write_Link"

  def stamp(rule: "update?", entry_point: "LinksController#update", decision: "allow", **facts)
    defaults = {
      policy: "LinkPolicy", resource: "Link", class_level: false, enforced: true, logged_in: true,
      in_current_tenant: true, roles: [], record_roles: ["owner"], current_roles: ["owner"]
    }
    Hallmark::Stamp.new(**defaults, entry_point: entry_point, rule: rule, decision: decision, **facts)
  end

  def set
    Hallmark::StampSet.new(
      [stamp, stamp(rule: "edit?", entry_point: "LinksController#edit")],
      [Hallmark::Unchecked.new(entry_point: "LinksController#show", status: 200, verb: "GET")],
      [Hallmark::Route.new(entry_point: "LinksController#update", verb: "PATCH", path: "/links/:id(.:format)")]
    )
  end

  def report(stamp_set = set, verdicts: {}, &extra)
    analysis = Hallmark::Analysis.build("Shop") do
      map do
        tenant "User", membership: "TeamMembership", self: :owner, roles_in: :team_roles_for
        current_tenant :seller
        resource "Link", tenant: :user
        grant :owner, :read, "Link"
        grant :owner, :write, "Link"
        instance_eval(&extra) if extra
      end
      stamps stamp_set
    end
    analysis.run(solver: FixtureSolver.new(verdicts))
  end

  def build(report = self.report, digest: "m1") = Hallmark::Baseline.build([report], mapping_digest: digest, run: "ci")

  def test_round_trip
    baseline = build(report(verdicts: { UPDATE => :counterexample }))

    Dir.mktmpdir do |dir|
      path = File.join(dir, "baseline.json")
      baseline.write(path)
      read = Hallmark::Baseline.load(path)

      assert_equal baseline.to_h, read.to_h
      assert_equal ["ci", [UPDATE], ["LinksController#show"]], [read.run, read.failing.map(&:name), read.unchecked]
      assert_equal %w[none counterexample], read.checks.map(&:verdict)
      assert_equal :write, read.checks.fetch(1).op
    end
  end

  # Watch seeds its stamps from these lines, so inference starts where CI's did.
  def test_it_holds_every_line_of_the_run
    read = Hallmark::Baseline.from_data(JSON.parse(build.to_json)).stamp_set

    assert_equal set.stamps, read.stamps
    assert_equal set.unchecked, read.unchecked
    assert_equal set.routes, read.routes
  end

  def test_digests_are_stable_and_follow_the_guard
    first = build.checks.to_h { |check| [check.name, check.digest] }

    assert_equal(first, build.checks.to_h { |check| [check.name, check.digest] })
    widened = Hallmark::StampSet.new(set.stamps + [stamp(in_current_tenant: false, record_roles: [])])
    changed = build(report(widened)).checks.to_h { |check| [check.name, check.digest] }

    assert_equal first.fetch("safe_LinksController_edit_read_Link"),
                 changed.fetch("safe_LinksController_edit_read_Link")
    refute_equal first.fetch(UPDATE), changed.fetch(UPDATE)
  end

  # The public action the mapping gives a rule changes the check, so its digest.
  def test_a_public_action_changes_the_digest
    plain = build.checks.find { |check| check.name == UPDATE }
    public_update = build(report { public_action "LinkPolicy", :update?, audience: :signed_in })
                    .checks.find { |check| check.name == UPDATE }

    refute_equal plain&.digest, public_update&.digest
  end

  def test_a_changed_mapping_scope_or_version_makes_it_stale
    baseline = build

    assert_empty baseline.stale_reasons(mapping_digest: "m1")
    assert_equal ["the mapping file changed"], baseline.stale_reasons(mapping_digest: "m2")
    assert_equal ["it was checked at scope 5, not 3"], baseline.stale_reasons(mapping_digest: "m1", scope: 3)
    old = Hallmark::Baseline.from_data(baseline.to_h.merge("hallmark" => "0.0.0"))

    assert_equal ["it was written by Hallmark 0.0.0, not #{Hallmark::VERSION}"], old.stale_reasons(mapping_digest: "m1")
  end

  def test_the_mapping_digest_is_of_the_files_bytes
    Dir.mktmpdir do |dir|
      path = File.join(dir, "hallmark.rb")
      File.write(path, "Hallmark.configure { }\n")

      assert_equal Digest::SHA256.hexdigest("Hallmark.configure { }\n"), Hallmark::Baseline.digest_files([path])
    end
  end

  def test_unknown_verdicts_are_recorded_as_such
    baseline = build(report(verdicts: { UPDATE => "timed out after 9 s" }))

    assert_equal ["unknown"], baseline.checks.select(&:unknown?).map(&:verdict)
    assert_empty baseline.failing
  end

  def test_refuses_what_is_not_a_baseline
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.json")
      File.write(path, "[]")

      assert_raises(Hallmark::ConfigurationError) { Hallmark::Baseline.load(path) }
      File.write(path, JSON.generate(build.to_h.merge("format" => 99)))
      error = assert_raises(Hallmark::ConfigurationError) { Hallmark::Baseline.load(path) }

      assert_match(/format 99/, error.message)
    end
  end
end
