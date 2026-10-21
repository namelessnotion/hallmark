# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "stringio"
require_relative "support/fixture_solver"

# `hallmark watch` end to end: the shop app (test/support/rails_app.rb)
# boots in a child process twice, once in test mode as CI would run it and
# once in shadow mode serving a cross-seller update (M2, current-tenant
# confusion), with hashed ids on. The baseline comes from the first run and
# the watch tails the second. The in-process half runs on FixtureSolver;
# the CLI and sidecar halves need Java and skip without it.
class WatchEndToEndTest < Minitest::Test
  APP = File.join(ROOT, "test", "support", "rails_app.rb")
  BIN = File.join(ROOT, "bin", "hallmark")
  # Shop.map with every class named in a string, so the CLI can load it.
  CONFIG = <<~RUBY
    Hallmark.configure do |config|
      config.map do
        principal "Shop::User", roles: ->(user) { user.staff? ? ["staff"] : [] }
        tenant "Shop::User", membership: "Shop::TeamMembership", self: :owner, roles_in: :team_roles_for
        current_tenant :seller
        platform_role :staff
        resource "Shop::Link", tenant: :user, permits: :collaborator_for?
        grant :owner, :read, "Shop::Link"
        grant :owner, :write, "Shop::Link"
        grant :admin, :read, "Shop::Link"
        grant :admin, :write, "Shop::Link"
        grant :marketing, :read, "Shop::Link"
      end
    end
  RUBY
  ROUTES = <<~RUBY
    Rails.application.routes.draw do
      get "/links/:id/edit" => "pundit_shop/links#edit"
      patch "/links/:id" => "pundit_shop/links#update"
    end
  RUBY
  UPDATE = "PunditShop::LinksController#update"

  def setup
    super
    @root = Dir.mktmpdir("hallmark-watch-app")
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(config, CONFIG)
    File.write(File.join(@root, "config", "routes.rb"), ROUTES)
    boot("test", "watch_ci", "HALLMARK_RUN" => "ci")
    boot("development", "watch_live", "HALLMARK_MODE" => "shadow", "HALLMARK_RUN" => "live", "HALLMARK_IDS" => "on",
                                      "HALLMARK_ID_KEY" => "k" * 32)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def config = File.join(@root, "config", "hallmark.rb")
  def stamps = File.join(@root, "tmp", "hallmark")

  def boot(environment, scenario, env)
    env = { "RAILS_ENV" => environment, "SHOP_SCENARIO" => scenario, "HALLMARK_MODE" => nil, "HALLMARK_STAMPS" => nil,
            "HALLMARK_SAMPLE" => nil, "HALLMARK_IDS" => nil, "HALLMARK_ID_KEY" => nil, "SHOP_EAGER_LOAD" => nil }
          .merge(env)
    _output, error, status = Open3.capture3(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), APP, @root)

    assert_predicate status, :success?, error
  end

  # CI's baseline built in this process, as `hallmark check --baseline` builds it.
  def baseline(solver)
    load config
    config_ = Hallmark.configuration
    config_.root = @root
    config_.stamps = stamps
    config_.run = "ci"
    report = Hallmark.analyze("shop") { stamps }.run(solver: solver)
    Hallmark::Baseline.build([report], mapping_digest: Hallmark::Baseline.digest_files([config]), run: "ci")
  end

  def watch(baseline, solver)
    @out = StringIO.new
    mapping = Hallmark.configuration.mapping || flunk("no mapping")
    source = Hallmark::Watch::FileTail.new(stamps, run: "live")
    Hallmark::Watch.new(mapping: mapping, baseline: baseline, source: source, solver: solver,
                        mapping_digest: Hallmark::Baseline.digest_files([config]), out: @out, err: StringIO.new)
  end

  def update_check(baseline) = baseline.checks.find { |check| check.action == UPDATE } || flunk("no update check")

  def test_the_cross_seller_update_is_the_one_new_finding
    baseline = baseline(FixtureSolver.new)
    name = update_check(baseline).name
    solver = FixtureSolver.new(name => :counterexample)
    watch = watch(baseline, solver)

    assert_equal 1, watch.run(once: true)
    assert_equal [name], solver.checks, "the edit stamp was a deny, so only the update check changed"
    assert_equal([[:finding, UPDATE]], watch.events.map { |event| [event.type, event.data["action"]] })
    user = OpenSSL::HMAC.hexdigest("SHA256", "k" * 32, "Shop::User:2")
    record = OpenSSL::HMAC.hexdigest("SHA256", "k" * 32, "Shop::Link:7")

    # ann, the current seller, has no id, so the example names no tenant.
    assert_includes @out.string, "first seen as user h:#{user[0, 12]}, record h:#{record[0, 12]}\n"
  end

  # The real thing: `hallmark check --baseline`, then `hallmark watch --once`.
  def test_the_cli_reports_it_from_live_stamps
    require_solver!
    env = { "HALLMARK_STAMPS" => stamps, "HALLMARK_RUN" => "ci", "HALLMARK_ROOT" => nil, "HALLMARK_SOLVER" => nil }
    out = File.join(@root, "baseline.json")
    output, error, status = Open3.capture3(env, RbConfig.ruby, BIN, "check", "--baseline", out, config)

    assert_equal 0, status.exitstatus, output + error
    output, error, status = Open3.capture3(env.merge("HALLMARK_RUN" => nil), RbConfig.ruby, BIN, "watch", "--once",
                                           "--solver", "cli", "--baseline", out, "--run", "live", config)

    assert_equal 1, status.exitstatus, output + error
    assert_equal 1, output.scan(/^FAIL /).size, output
    assert_includes output, "FAIL  #{UPDATE} (write Shop::Link)"
    assert_includes output, "first seen as user h:"
    assert_includes output, "2 new stamps; 1 check run: 1 new counterexample."
  end

  # On the sidecar: one JVM serves both batches.
  def test_one_sidecar_serves_every_batch
    require_solver!
    sidecar = require_sidecar!
    baseline = baseline(Hallmark::Solver::CLI.new)

    assert_equal "none", update_check(baseline).verdict
    watch = watch(baseline, sidecar)
    first = watch.poll
    pid = sidecar.pid

    assert_equal 1, first&.checks
    assert_equal [:finding], watch.events.map(&:type)
    File.write(Dir[File.join(stamps, "stamps-live-*.jsonl")].first, "#{widen_again}\n", mode: "a")
    second = watch.poll

    assert_equal [1, 1], [second&.checks, second&.known]
    assert_equal [pid, 1], [sidecar.pid, sidecar.starts]
  ensure
    sidecar&.close
  end

  # Another allow on the update rule, outside the current tenant: the guard
  # changes again, and the check, already failing, is known.
  def widen_again
    Hallmark::Stamp.new(entry_point: UPDATE, policy: "PunditShop::LinkPolicy", rule: "update?", resource: "Shop::Link",
                        class_level: false, enforced: true, decision: "allow", logged_in: true, owner: nil,
                        public_record: nil, member: false, in_current_tenant: false, outside_tenants: nil,
                        granted: true, permitted: false, roles: [], record_roles: [], current_roles: ["owner"])
                   .to_json_line
  end
end
