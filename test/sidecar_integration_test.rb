# frozen_string_literal: true

require "test_helper"

# The real sidecar (`bin/hallmark install-sidecar`), cross-checked against
# the CLI backend. Skipped when the sidecar or Java is missing.
class SidecarIntegrationTest < Minitest::Test
  def teardown
    @sidecar&.close
    super
  end

  def sidecar
    require_solver!
    @sidecar = require_sidecar!
  end

  def verdicts(report)
    {
      findings: report.findings.map { |finding| finding.exposure.action },
      verified: report.verified.map(&:action),
      unknown: report.unknown.map { |item| item.exposure.action }
    }
  end

  # Same verdicts from both backends, and every sidecar witness decodes into
  # a finding; one sidecar process serves both examples.
  def test_cross_check_with_the_cli
    solver = sidecar
    cli = Hallmark::Solver::CLI.new
    %w[medium_clone/hallmark.rb storefront/hallmark.rb].each do |example|
      analysis = load_example(example)
      expected = analysis.run(solver: cli)
      actual = analysis.run(solver: solver)

      assert_equal verdicts(expected), verdicts(actual), example
      actual.findings.each { |finding| refute_nil finding.record, example }
    end
    assert_equal 1, solver.starts
  end

  def test_storefront_finding_reads_like_the_cli_one
    report = load_example("storefront/hallmark.rb").run(solver: sidecar)
    finding = report.findings.fetch(0)

    assert_predicate finding, :cross_tenant?
    refute_predicate finding, :anonymous?
  end

  # Ramsey R(4,4) over 60 vertices: translating it alone takes far longer
  # than a second.
  SLOW = <<~ALS
    sig V { red: set V }
    fact { red = ~red and no iden & red }
    check ramsey {
      some disj a, b, c, d: V | let k = (a + b + c + d) -> (a + b + c + d) - iden |
        k in red or no k & red
    } for exactly 60 V
  ALS

  def test_a_timeout_is_unknown_and_the_next_check_gets_a_new_sidecar
    Hallmark.configure { |config| config.timeout = 1 }
    solver = sidecar
    slow = Hallmark::ModelBuilder::Model.new(source: SLOW, checks: { "ramsey" => nil }, analysis: nil)
    first_pid = solver.call("version") && solver.pid
    command = solver.check(slow)["ramsey"]

    assert_predicate command, :unknown?
    assert_equal "timed out after 1 s", command.reason
    refute_predicate solver, :running?

    report = load_example("medium_clone/hallmark.rb").run(solver: solver)

    assert_equal 2, report.findings.size
    assert_equal 2, solver.starts
    refute_equal first_pid, solver.pid
  end

  def test_eval_and_scope_over_the_protocol
    solver = sidecar
    source = "sig A {}\nrun three { #A = 3 } for 2\n"
    model = solver.call("load", { "source" => source })["model_id"]

    assert_equal "unsat", solver.call("check", { "model_id" => model, "command" => "three" })["verdict"]
    result = solver.call("check", { "model_id" => model, "command" => "three", "scope" => 3 })

    assert_equal "sat", result["verdict"]
    value = solver.call("eval", { "model_id" => model, "instance_id" => result["instance_id"], "expr" => "#A" })

    assert_equal "3", value["value"].to_s
  end

  def test_an_alloy_syntax_error_is_reported
    error = assert_raises(Hallmark::SolverError) { sidecar.call("load", { "source" => "sig A {" }) }

    assert_includes error.message, "rror"
  end
end
