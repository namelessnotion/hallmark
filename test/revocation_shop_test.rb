# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# The revocation shop example end to end (phase 3 step 9): an admin
# downgraded to marketing keeps editing a product through a role cached
# across requests. From the stamps recorded in
# test/fixtures/revocation_shop_stamps (no Java): one R1 lint and one stale
# access, none for the fixed app. Then scenario.rb in a child process
# (Rails, Active Record on SQLite, the collectors in test mode) and the real
# backends, the soft-delete variant included.
class RevocationShopTest < Minitest::Test
  STAMPS = File.join(HallmarkTestHelpers::FIXTURES, "revocation_shop_stamps")
  SCENARIO = File.join(HallmarkTestHelpers::ROOT, "examples", "revocation_shop", "scenario.rb")

  def analysis(file, stamps)
    with_env("HALLMARK_STAMPS" => stamps, "HALLMARK_RUN" => nil) { load_example("revocation_shop/#{file}") }
  end

  def report(file = "hallmark.rb", stamps = File.join(STAMPS, "buggy"))
    Hallmark::Report.new(analysis(file, stamps), Hallmark::Receipt.load(File.join(FIXTURES, "revocation_shop")))
  end

  def test_the_buggy_shop_has_one_lint_and_one_stale_access
    found = report

    assert_empty found.findings
    assert_equal ["R1"], found.lints.map(&:kind)
    assert_equal "app/models/user.rb:13", found.lints.first.location
    assert_equal([["LinkPolicy#update?", ["admin"]]], found.stale_access.map { |item| [item.rule, item.revoked] })
    assert_equal 1, found.exit_code
    assert_includes found.to_s, "No counterexamples in 1 check, 1 stale allow after revocation, 1 revocation hazard."
  end

  def test_the_fixed_shop_is_clean
    found = report("hallmark_fixed.rb", File.join(STAMPS, "fixed"))

    assert_empty found.lints
    assert_empty found.stale_access
    assert_equal 0, found.exit_code
  end

  def test_sarif_has_the_lint_and_the_stale_access
    log = JSON.parse(Hallmark::Sarif.new([report]).to_json)
    results = log.dig("runs", 0, "results").map { |result| [result["ruleId"], result.dig("locations", 0)] }

    assert_equal %w[hallmark/stale hallmark/R1], results.map(&:first)
    assert_equal({ "artifactLocation" => { "uri" => "app/models/user.rb" }, "region" => { "startLine" => 13 } },
                 results.last.last["physicalLocation"])
  end

  # Runs scenario.rb into a fresh stamp directory; the update statuses.
  def scenario(dir, *)
    env = { "HALLMARK_STAMPS" => dir, "HALLMARK_RUN" => nil, "HALLMARK_MODE" => nil }
    output, error, status = Open3.capture3(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), SCENARIO, *)
    assert_predicate status, :success?, error
    JSON.parse(output.lines.last).fetch("statuses")
  end

  def checked(file, dir, solver, run: "scenario")
    with_env("HALLMARK_RUN" => run) do
      found = analysis(file, dir).run(solver: solver)
      [found.findings.size, found.stale_access.size, found.lints.size, found.exit_code]
    end
  end

  def verdicts(solver)
    Dir.mktmpdir("hallmark-revocation") do |dir|
      buggy = File.join(dir, "buggy")
      fixed = File.join(dir, "fixed")

      assert_equal [200, 200], scenario(buggy)
      assert_equal [200, 200], scenario(buggy, "soft_delete")
      assert_equal [200, 403], scenario(fixed, "fixed")
      [checked("hallmark.rb", buggy, solver), checked("hallmark.rb", buggy, solver, run: "softdelete"),
       checked("hallmark_fixed.rb", fixed, solver)]
    end
  end

  def test_scenario_buggy_and_fixed_on_the_cli
    solver = require_solver!

    assert_equal [[0, 1, 1, 1], [0, 1, 1, 1], [0, 0, 0, 0]], verdicts(solver)
  end

  def test_scenario_buggy_and_fixed_on_the_sidecar
    require_solver!
    sidecar = require_sidecar!

    assert_equal [[0, 1, 1, 1], [0, 1, 1, 1], [0, 0, 0, 0]], verdicts(sidecar)
  ensure
    sidecar&.close
  end
end
