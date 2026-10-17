# frozen_string_literal: true

require "test_helper"

# Picking a backend, and how a check with no verdict reads in a report.
class SolverTest < Minitest::Test
  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved&.each { |key, value| ENV[key] = value }
  end

  # `true` and `false` stand in for java: the exit status decides.
  def test_java_runs_when_the_command_exits_zero
    assert Hallmark::Solver.java_runs?("true")
    refute Hallmark::Solver.java_runs?("false")
    refute Hallmark::Solver.java_runs?("/nonexistent/java")
  end

  def test_kill_stops_a_process
    pid = Process.spawn("sleep", "30")
    Hallmark::Solver.kill(pid)
    _, status = Process.wait2(pid)

    assert_equal 9, status.termsig
  end

  # A pid far above any real one, so the test never signals another process.
  def test_kill_ignores_a_process_that_is_gone
    assert_nil Hallmark::Solver.kill(2**30)
  end

  def test_cli_is_the_default_backend
    assert_equal :cli, Hallmark.configuration.solver
    assert_instance_of Hallmark::Solver::CLI, Hallmark.solver
  end

  def test_the_sidecar_is_chosen_in_code_or_the_environment
    Hallmark.configure { |config| config.solver = :sidecar }

    assert_instance_of Hallmark::Solver::Sidecar, Hallmark.solver
    with_env("HALLMARK_SOLVER" => "sidecar") do
      assert_equal :sidecar, Hallmark::Configuration.new.solver
    end
  end

  # HALLMARK_SOLVER used to name the SAT solver.
  def test_a_sat_solver_name_points_to_its_own_setting
    error = assert_raises(Hallmark::ConfigurationError) { Hallmark.configuration.solver = "minisat" }

    assert_includes error.message, "HALLMARK_SAT_SOLVER=minisat"
    assert_raises(Hallmark::ConfigurationError) { Hallmark.configuration.solver = :jruby }
  end

  def test_the_sat_solver_and_heap_come_from_the_environment
    with_env("HALLMARK_SAT_SOLVER" => "glucose", "HALLMARK_SIDECAR_HEAP" => "1024") do
      config = Hallmark::Configuration.new

      assert_equal "glucose", config.sat_solver
      assert_equal 1024, config.sidecar_heap
    end
  end

  def test_the_sidecar_jar_is_named_by_its_sources
    assert_match(/hallmark-solver-\h{12}\.jar\z/, Hallmark.configuration.sidecar_jar)
    refute_empty Hallmark::SidecarInstaller.sources
  end

  def test_hallmark_sidecar_jar_wins_over_the_default_path
    with_env("HALLMARK_SIDECAR_JAR" => "/opt/hallmark/solver.jar") do
      assert_equal "/opt/hallmark/solver.jar", Hallmark::Configuration.new.sidecar_jar
    end
  end

  def test_a_sidecar_jar_set_in_code_is_returned_as_is
    config = Hallmark::Configuration.new
    config.sidecar_jar = "/tmp/custom-solver.jar"

    assert_equal "/tmp/custom-solver.jar", config.sidecar_jar
  end

  def unknown_report
    analysis = load_example("medium_clone/hallmark_fixed.rb")
    names = analysis.exposures.map(&:check_name)
    Hallmark::Report.new(analysis, Hallmark::Receipt.unknown(names, "timed out after 1 s"))
  end

  def test_unknown_checks_exit_2_and_never_read_as_no_counterexample
    report = unknown_report

    assert_equal 6, report.unknown.size
    assert_empty report.verified
    refute_predicate report, :clean?
    assert_equal 2, report.exit_code
    assert_includes report.to_s, "??    UsersController#show (read User): unknown, timed out after 1 s"
    refute_includes report.to_s, "No counterexamples"
  end

  def test_exit_code_over_reports
    failing = Hallmark::Report.new(load_example("medium_clone/hallmark.rb"),
                                   Hallmark::Receipt.load(File.join(FIXTURES, "medium_clone")))

    assert_equal 1, Hallmark::Report.exit_code([unknown_report, failing])
    assert_equal 2, Hallmark::Report.exit_code([unknown_report])
    assert_equal 0, Hallmark::Report.exit_code([])
  end

  # A CLI run that outlives the timeout leaves every check unknown.
  def test_a_cli_timeout_makes_every_check_unknown
    Dir.mktmpdir("hallmark-slow-java") do |dir|
      java = File.join(dir, "java")
      File.write(java, "#!/bin/sh\nexec sleep 30\n")
      File.chmod(0o755, java)
      Hallmark.configure do |config|
        config.java = java
        config.alloy_jar = java
        config.timeout = 1
      end
      report = load_example("medium_clone/hallmark.rb").run(solver: Hallmark::Solver::CLI.new)

      assert_equal 6, report.unknown.size
      assert_equal ["the Alloy run timed out after 1 s"], report.unknown.map(&:reason).uniq
    end
  end
end
