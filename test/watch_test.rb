# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "support/fixture_solver"

# `hallmark watch` (phase 3 step 3) on hand-built stamps and FixtureSolver:
# what counts as new, what goes to the solver, and the file and Redis
# tails; no Java.
class WatchTest < Minitest::Test
  include Hallmark::Guard::DSL

  UPDATE = "safe_LinksController_update_write_Link"
  EDIT = "safe_LinksController_edit_read_Link"
  USER = "a1" * 32
  RECORD = "b2" * 32

  MAP = proc do
    tenant "User", membership: "TeamMembership", self: :owner, roles_in: :team_roles_for
    current_tenant :seller
    platform_role :staff
    resource "Link", tenant: :user
    grant :owner, :read, "Link"
    grant :owner, :write, "Link"
    grant :admin, :read, "Link"
    grant :admin, :write, "Link"
  end

  def setup
    super
    @dir = Dir.mktmpdir("hallmark-watch")
    Hallmark.configuration.root = @dir
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def stamp(rule: "update?", entry_point: "LinksController#update", decision: "allow", **facts)
    defaults = {
      policy: "LinkPolicy", resource: "Link", class_level: false, enforced: true, logged_in: true,
      in_current_tenant: true, roles: [], record_roles: ["owner"], current_roles: ["owner"]
    }
    Hallmark::Stamp.new(**defaults, entry_point: entry_point, rule: rule, decision: decision, **facts)
  end

  # The M2 shape: the current seller's admin updates another seller's link.
  def cross_seller = stamp(in_current_tenant: false, current_roles: ["admin"], record_roles: [])

  def owner_stamps = [stamp, stamp(rule: "edit?", entry_point: "LinksController#edit")]

  def unchecked(entry_point) = Hallmark::Unchecked.new(entry_point: entry_point, status: 200, verb: "GET")

  # CI's baseline over `stamps`, with FixtureSolver giving `verdicts`; and
  # the mapping it was checked with.
  def baseline(stamps = owner_stamps, unchecked: [], verdicts: {}, map: MAP)
    stamp_set = Hallmark::StampSet.new(stamps, unchecked)
    analysis = Hallmark::Analysis.build("Shop") do
      map(&map)
      stamps stamp_set
    end
    report = analysis.run(solver: FixtureSolver.new(verdicts))
    [Hallmark::Baseline.build([report], mapping_digest: "m1", run: "ci"), analysis.mapping]
  end

  def watch(baseline, mapping, solver, source: Hallmark::Watch::FileTail.new(@dir, run: "live"), digest: "m1",
            **)
    @out = StringIO.new
    @err = StringIO.new
    Hallmark::Watch.new(mapping: mapping, baseline: baseline, source: source, solver: solver, mapping_digest: digest,
                        out: @out, err: @err, **)
  end

  # Appends lines to a live run's file, as a worker's flusher does.
  def write(*lines, pid: 100, run: "live")
    File.open(File.join(@dir, "stamps-#{run}-#{pid}.jsonl"), "a") { |file| file.write(lines.map { "#{_1}\n" }.join) }
  end

  def example = Hallmark::Example.new(user: USER, record: RECORD)

  def test_a_live_stamp_that_widens_a_guard_is_one_new_finding
    solver = FixtureSolver.new(UPDATE => :counterexample)
    watch = watch(*baseline, solver)
    write(cross_seller.to_json_line(example), stamp.to_json_line)
    batch = watch.poll

    assert_equal [UPDATE], solver.checks, "only the exposure the stamp changed is checked"
    assert_equal [:finding], watch.events.map(&:type)
    assert_equal [2, 1, 1], [batch.lines, batch.stamps, batch.checks]
    text = @out.string

    assert_includes text, "FAIL  LinksController#update (write Link)"
    assert_includes text, "      first seen as user h:#{USER[0, 12]}, record h:#{RECORD[0, 12]}"
    assert_includes text, "1 new stamp; 1 check run: 1 new counterexample."
  end

  # A list exposure (phase 3 step 7) is re-checked when a live record
  # widens its inferred guard.
  def test_a_list_whose_guard_widens_is_checked_again
    list = "list_LinksController_index_Link"
    listed = lambda do |**facts|
      stamp(rule: "Scope#resolve", entry_point: "LinksController#index", enforced: false, list: true, **facts)
    end
    solver = FixtureSolver.new(list => :none)
    watch = watch(*baseline(owner_stamps + [listed.call]), solver)
    write(listed.call(in_current_tenant: false, record_roles: ["admin"]).to_json_line)
    watch.poll

    assert_equal [list], solver.checks
    assert_includes @out.string, "1 check run"
  end

  def test_a_poll_with_no_new_lines_sends_nothing
    solver = FixtureSolver.new(UPDATE => :counterexample)
    watch = watch(*baseline, solver)
    write(cross_seller.to_json_line)
    watch.poll

    assert_nil watch.poll
    assert_equal [UPDATE], solver.checks
    assert_equal 1, watch.exit_code
  end

  def test_the_first_batch_with_nothing_new_checks_nothing
    solver = FixtureSolver.new
    watch = watch(*baseline, solver)

    assert_equal 0, watch.poll&.checks
    assert_empty solver.checks
    assert_equal 0, watch.exit_code
    assert_includes @out.string, "0 new stamps; no check changed."
  end

  def test_run_once_exits_with_the_status_of_whats_new_and_closes_the_solver
    solver = FixtureSolver.new(UPDATE => :counterexample)
    watch = watch(*baseline, solver)
    write(cross_seller.to_json_line)

    assert_equal 1, watch.run(once: true)
    assert_predicate solver, :closed?
    assert_match(/\AHallmark .* watch, Alloy .*; baseline of run ci: 2 checks, 0 failing; watching .*\(run live\)/,
                 @out.string)
    refute_includes @out.string, "first seen as", "no example without ids"
  end

  # Without --once: batches until SIGINT, then the previous handler is back.
  def test_runs_until_interrupted_then_closes_the_solver
    solver = FixtureSolver.new(UPDATE => :counterexample)
    watch = watch(*baseline, solver)
    previous = trap("INT", "DEFAULT")
    trap("INT", previous)
    write(cross_seller.to_json_line)
    interrupt = Thread.new do
      sleep 0.3
      Process.kill("INT", Process.pid)
    end

    assert_equal 0, watch.run(interval: 0.05)
    assert_predicate solver, :closed?
    assert_equal [:finding], watch.events.map(&:type)
    assert_equal previous, trap("INT", previous)
  ensure
    interrupt&.join
  end

  def test_a_check_already_failing_is_not_repeated
    solver = FixtureSolver.new(UPDATE => :counterexample)
    watch = watch(*baseline(verdicts: { UPDATE => :counterexample }), solver)
    write(cross_seller.to_json_line)
    batch = watch.poll

    assert_equal [UPDATE], solver.checks
    assert_empty watch.events
    assert_equal 1, batch&.known
    assert_includes @out.string, "1 check run: 0 new counterexamples, 1 already known."
    assert_equal 0, watch.exit_code
  end

  def test_a_check_that_stops_failing_is_reported_once
    verdicts = { UPDATE => :counterexample }
    solver = FixtureSolver.new
    watch = watch(*baseline(verdicts: verdicts), solver)
    write(cross_seller.to_json_line)
    watch.poll
    write(stamp(in_current_tenant: false, current_roles: ["owner"], record_roles: []).to_json_line)
    watch.poll

    assert_equal [UPDATE, UPDATE], solver.checks, "the second stamp widens the guard again"
    assert_equal [:resolved], watch.events.map(&:type)
    assert_includes @out.string, "ok    LinksController#update (write Link): no longer fails, " \
                                 "no counterexample within scope 5"
    assert_equal 0, watch.exit_code, "no longer failing is not a failure"
  end

  # Once a check is reported, later batches that widen it again are already known.
  def test_a_finding_is_reported_once_across_batches
    solver = FixtureSolver.new(UPDATE => :counterexample)
    watch = watch(*baseline, solver)
    write(cross_seller.to_json_line)
    watch.poll
    write(stamp(in_current_tenant: false, current_roles: ["owner"], record_roles: []).to_json_line)
    batch = watch.poll

    assert_equal [UPDATE, UPDATE], solver.checks
    assert_equal [:finding], watch.events.map(&:type)
    assert_equal 1, batch&.known
  end

  def test_unknowns_are_retried_when_new_stamps_touch_the_exposure
    solver = FixtureSolver.new(UPDATE => "timed out after 9 s")
    watch = watch(*baseline, solver)
    write(cross_seller.to_json_line)
    watch.poll

    assert_equal [:unknown], watch.events.map(&:type)
    assert_includes @out.string, "??    LinksController#update (write Link): unknown, timed out after 9 s"
    assert_equal 2, watch.exit_code
    write(stamp(rule: "edit?", entry_point: "LinksController#edit", current_roles: ["admin"],
                record_roles: ["admin"]).to_json_line)
    watch.poll

    assert_equal [UPDATE, EDIT], solver.checks, "an edit stamp does not touch the update check"
    write(stamp(rule: "update?", decision: "deny", current_roles: [], record_roles: []).to_json_line)
    watch.poll

    assert_equal [UPDATE, EDIT, UPDATE], solver.checks, "a stamp of the update rule does"
  end

  def test_new_unchecked_entry_points_only
    watch = watch(*baseline(unchecked: [unchecked("LinksController#show")]), FixtureSolver.new)
    write(unchecked("LinksController#show").to_json_line, unchecked("LinksController#archive").to_json_line)
    watch.poll

    assert_equal([["unchecked", "LinksController#archive"]],
                 watch.events.map { |event| [event.to_h["type"], event.to_h["entry_point"]] })
    assert_includes @out.string, "FAIL  LinksController#archive finished without an authorization call (threat 10)"
    assert_equal 1, watch.exit_code
  end

  def test_new_drift_only
    Hallmark.configuration.root = File.join(FIXTURES, "apps", "shop")
    terms = proc do
      instance_eval(&MAP)
      resources["Link"].permits = :collaborator_for?
      term "user.role_owner_for?(seller)", role(:owner, tenant: :current)
      term "user.role_admin_for?(seller)", role(:admin, tenant: :current)
      term "user.role_marketing_for?(seller)", role(:marketing, tenant: :current)
    end
    base, mapping = baseline(map: terms)
    watch = watch(base, mapping, FixtureSolver.new, extractor: Hallmark::Extractor.load(mapping))
    write(stamp(current_roles: ["marketing"], record_roles: ["marketing"], permitted: false).to_json_line)
    watch.poll

    assert_equal [:drift], watch.events.map(&:type)
    assert_match(%r{\ADRIFT LinkPolicy#update\? \(Link\) at app/policies/link_policy.rb:\d+: allowed}, @out.string.lines
      .grep(/DRIFT/).first)
  end

  def test_a_stale_baseline_checks_everything_once_and_keeps_known_failures
    solver = FixtureSolver.new(UPDATE => :counterexample)
    watch = watch(*baseline(verdicts: { UPDATE => :counterexample }), solver, digest: "m2")
    watch.poll

    assert_match(/the baseline is stale \(the mapping file changed\); checking every exposure once/, @err.string)
    assert_equal [EDIT, UPDATE], solver.checks.sort
    assert_empty watch.events, "a failure the baseline knew is not new"
    assert_nil watch.poll
  end

  def test_json_events_and_on_finding
    received = []
    on_finding = lambda do |event|
      received << event.type
      raise "alerting is down"
    end
    watch = watch(*baseline(unchecked: []), FixtureSolver.new(UPDATE => :counterexample), json: true,
                                                                                          on_finding: on_finding)
    write(cross_seller.to_json_line(example), unchecked("LinksController#archive").to_json_line)
    watch.poll

    assert_equal %i[finding unchecked], received, "called once per event, despite raising"
    assert_equal 2, @err.string.scan("on_finding raised RuntimeError: alerting is down").size
    events = @out.string.lines.map { |line| JSON.parse(line) }

    assert_equal(%w[finding unchecked], events.map { |event| event["type"] })
    finding = events.fetch(0)

    assert_equal [UPDATE, "LinksController#update", "write", "Link"],
                 finding.values_at("check", "action", "op", "resource")
    assert_equal({ "user" => USER, "record" => RECORD, "tenant" => nil }, finding["example"])
    assert finding["message"]
  end

  def test_on_finding_comes_from_the_configuration
    received = []
    Hallmark.configure { |c| c.on_finding = ->(event) { received << event.type } }
    watch = watch(*baseline, FixtureSolver.new(UPDATE => :counterexample))
    write(cross_seller.to_json_line)
    watch.poll

    assert_equal [:finding], received
    assert_raises(Hallmark::ConfigurationError) { Hallmark.configuration.on_finding = "page me" }
  end

  def test_the_sarif_log_holds_everything_new_since_start
    sarif = File.join(@dir, "watch.sarif")
    watch = watch(*baseline, FixtureSolver.new(UPDATE => :counterexample), sarif: sarif, sarif_fallback: "hallmark.rb")
    watch.poll

    assert_empty JSON.parse(File.read(sarif)).dig("runs", 0, "results")
    write(cross_seller.to_json_line)
    watch.poll
    write(unchecked("LinksController#archive").to_json_line)
    watch.poll
    results = JSON.parse(File.read(sarif)).dig("runs", 0, "results")

    assert_equal(%w[hallmark/counterexample hallmark/unchecked], results.map { |result| result["ruleId"] })
  end

  def test_a_line_that_is_not_json_is_skipped
    watch = watch(*baseline, FixtureSolver.new(UPDATE => :counterexample))
    write("{not json", cross_seller.to_json_line)
    watch.poll

    assert_equal [:finding], watch.events.map(&:type)
    assert_includes @err.string, "skipped a line that is not JSON: {not json"
  end

  def test_the_file_tail_holds_a_partial_line_until_it_is_complete
    tail = Hallmark::Watch::FileTail.new(@dir, run: "live")
    line = cross_seller.to_json_line
    File.write(File.join(@dir, "stamps-live-100.jsonl"), "#{line}\n#{line[0, 20]}")

    assert_equal [line], tail.poll
    assert_empty tail.poll
    File.write(File.join(@dir, "stamps-live-100.jsonl"), "#{line[20..]}\n", mode: "a")

    assert_equal [line], tail.poll
  end

  def test_the_file_tail_picks_up_new_workers_and_ignores_other_runs
    tail = Hallmark::Watch::FileTail.new(@dir, run: "live")
    write("a", pid: 100)
    write("ci", run: "ci")

    assert_equal ["a"], tail.poll
    write("b", pid: 200)
    write("c", pid: 100)

    assert_equal %w[c b], tail.poll
  end

  def test_the_file_tail_keeps_the_newest_run_it_found_first
    tail = Hallmark::Watch::FileTail.new(@dir)

    assert_empty tail.poll
    assert_nil tail.run
    write("a", run: "deploy1")

    assert_equal ["a"], tail.poll
    assert_equal "deploy1", tail.run
    write("b", run: "deploy2")

    assert_empty tail.poll
  end

  # redis-rb: xread and xrevrange, fields as a Hash.
  class RedisRb
    attr_reader :reads

    def initialize(entries)
      @entries = entries
      @reads = []
    end

    def xrevrange(_stream, _last, _first, count:) = @entries.last(count).reverse

    def xread(stream, last, count:, block: nil)
      @reads << [stream, last, block]
      found = @entries.select { |(entry_id, _)| (entry_id <=> last).positive? }.first(count)
      found.empty? ? {} : { stream => found }
    end

    def add(entry_id, run, line) = @entries << [entry_id, { "run" => run, "line" => line }]
  end

  # redis-client: call (and blocking_call), fields as a flat Array, RESP2 shape.
  class RedisClientFake
    attr_reader :commands

    def initialize(entries)
      @entries = entries
      @commands = []
    end

    def call(*args)
      @commands << args
      case args.first
      when "XREVRANGE" then @entries.last(1).map { |(id, fields)| [id, fields.to_a.flatten] }
      when "XREAD"
        stream, id = args.last(2)
        found = @entries.select { |(entry_id, _)| (entry_id <=> id).positive? }
        found.empty? ? nil : [[stream, found.map { |(entry_id, fields)| [entry_id, fields.to_a.flatten] }]]
      end
    end

    def blocking_call(_timeout, *) = call(*)
  end

  def entries
    [["1-0", { "run" => "live", "line" => "old" }], ["2-0", { "run" => "other", "line" => "x" }]]
  end

  def test_the_redis_tail_reads_new_entries_of_its_run_with_redis_rb
    client = RedisRb.new(entries)
    tail = Hallmark::Watch::RedisTail.new(client, run: "live", block: 2000)

    assert_empty tail.poll, "starts after the stream's last entry"
    client.add("3-0", "live", "new")
    client.add("4-0", "other", "skip")

    assert_equal ["new"], tail.poll
    assert_equal ["hallmark:stamps", "2-0", 2000], client.reads.last
    assert_predicate tail, :blocking?
  end

  def test_the_redis_tail_reads_from_the_start_with_redis_client
    client = RedisClientFake.new(entries)
    tail = Hallmark::Watch::RedisTail.new(client, stream: "s", all_runs: true, from_start: true)

    assert_equal %w[old x], tail.poll
    assert_equal %w[XREAD COUNT 1000 STREAMS s 0-0], client.commands.first
    refute_predicate tail, :blocking?
    blocking = Hallmark::Watch::RedisTail.new(client, stream: "s", run: "live", block: 500)
    blocking.poll

    assert_equal %w[XREAD COUNT 1000 BLOCK 500 STREAMS s 2-0], client.commands.last
  end

  def test_the_redis_tail_needs_a_run_and_a_client
    assert_raises(Hallmark::ConfigurationError) { Hallmark::Watch::RedisTail.new(RedisRb.new([])) }
    assert_raises(Hallmark::ConfigurationError) { Hallmark::Watch::RedisTail.new(Object.new, run: "live") }
  end

  def test_watch_over_a_redis_stream
    client = RedisRb.new([])
    watch = watch(*baseline, FixtureSolver.new(UPDATE => :counterexample),
                  source: Hallmark::Watch::RedisTail.new(client, run: "live"))
    watch.poll
    client.add("1-0", "live", cross_seller.to_json_line)
    watch.poll

    assert_equal [:finding], watch.events.map(&:type)
  end
end
