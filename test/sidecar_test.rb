# frozen_string_literal: true

require "test_helper"

# The sidecar client against test/support/fake_sidecar.rb, a Ruby process
# speaking the sidecar's protocol with verdicts from test/fixtures, so these
# tests need no Java.
class SidecarTest < Minitest::Test
  def setup
    super
    @state = Dir.mktmpdir("hallmark-fake-sidecar")
    @sidecars = []
  end

  def teardown
    @sidecars.each(&:close)
    FileUtils.rm_rf(@state)
    super
  end

  def sidecar(mode, timeout: 5)
    Hallmark.configure { |config| config.timeout = timeout }
    fake_sidecar(mode, @state).tap { |sidecar| @sidecars << sidecar }
  end

  def requests(method)
    File.readlines(File.join(@state, "requests.jsonl")).map { |line| JSON.parse(line) }
        .select { |request| request["method"] == method }
  end

  def medium_clone = load_example("medium_clone/hallmark.rb")

  def test_findings_match_the_cli_receipt
    analysis = medium_clone
    expected = Hallmark::Report.new(analysis, Hallmark::Receipt.load(File.join(FIXTURES, "medium_clone")))
    report = analysis.run(solver: sidecar("ok"))

    assert_equal expected.findings.map(&:message), report.findings.map(&:message)
    assert_equal expected.verified.map(&:action), report.verified.map(&:action)
    assert_empty report.unknown
  end

  def test_one_process_serves_every_analysis
    solver = sidecar("ok")
    medium_clone.run(solver: solver)
    load_example("storefront/hallmark.rb").run(solver: solver)

    assert_equal 1, solver.starts
    assert_equal 2, requests("load").size
    assert_equal 2, requests("unload").size
    assert_equal 11, requests("check").size
  end

  def test_checks_carry_the_per_check_timeout
    medium_clone.run(solver: sidecar("ok", timeout: 7))

    assert(requests("check").all? { |request| request.dig("params", "timeout_ms") == 7000 })
    assert_includes requests("load").first.dig("params", "modules"), "catalog"
  end

  # The fake never answers the first check; the client stops waiting, kills
  # it, reports unknown, and starts a new one (loading the model again) for
  # the next check.
  def test_a_check_with_no_answer_is_unknown_and_the_sidecar_restarts
    solver = sidecar("hang-once", timeout: 1)
    report = medium_clone.run(solver: solver)

    assert_equal(["UsersController#show"], report.unknown.map { |item| item.exposure.action })
    assert_equal "timed out after 1 s", report.unknown.first.reason
    assert_equal 2, report.findings.size
    assert_equal 2, solver.starts
    assert_equal 2, requests("load").size
  end

  def test_an_unknown_answer_restarts_the_sidecar
    solver = sidecar("unknown-once", timeout: 3)
    report = medium_clone.run(solver: solver)

    assert_equal ["timed out after 3 s"], report.unknown.map(&:reason)
    assert_equal 5, report.findings.size + report.verified.size
    assert_equal 2, solver.starts
  end

  def test_a_crash_is_unknown_with_the_sidecars_last_words
    solver = sidecar("crash-once")
    report = medium_clone.run(solver: solver)
    reason = report.unknown.fetch(0).reason

    assert_includes reason, "exited with status 3"
    assert_includes reason, "OutOfMemoryError"
    assert_equal 2, solver.starts
  end

  # A model that cannot be loaded will not load on a retry either (same model,
  # same heap), so the run stops there: every check is unknown, with one start.
  def test_a_crash_while_loading_makes_every_check_unknown
    solver = sidecar("load-crash")
    report = medium_clone.run(solver: solver)

    assert_equal 6, report.unknown.size
    assert_equal 1, report.unknown.map(&:reason).uniq.size
    assert_includes report.unknown.first.reason, "OutOfMemoryError"
    assert_includes report.unknown.first.reason, "while loading the model"
    assert_equal 1, solver.starts
    assert_equal 1, requests("load").size
  end

  # After a restart the model is loaded again; when that load hangs, the
  # first check's verdict is kept and the rest are unknown.
  def test_a_load_timeout_after_a_restart_makes_the_rest_unknown
    solver = sidecar("load-hang-second", timeout: 1)
    report = medium_clone.run(solver: solver)

    assert_equal 6, report.unknown.size
    assert_equal ["timed out after 1 s", "timed out loading the model after 1 s"], report.unknown.map(&:reason).uniq
    assert_equal 2, solver.starts
  end

  # A crash, then a sidecar that will not start again: the crashed check and
  # the rest are unknown, and the run does not try to start it once per check.
  def test_a_failed_restart_makes_the_rest_unknown
    solver = sidecar("crash-then-die")
    report = medium_clone.run(solver: solver)
    reasons = report.unknown.map(&:reason)

    assert_equal 6, reasons.size
    assert_includes reasons.first, "exited with status 3"
    assert_equal 1, reasons.drop(1).uniq.size
    assert_includes reasons.last, "did not start"
    assert_includes reasons.last, "refusing to start"
    assert_equal 2, solver.starts
  end

  # Unloading only frees memory, so a crash there keeps every verdict; the
  # next run starts another sidecar.
  def test_a_crash_while_unloading_keeps_the_verdicts
    solver = sidecar("unload-crash")
    report = medium_clone.run(solver: solver)

    assert_equal 2, report.findings.size
    assert_empty report.unknown
    refute_predicate solver, :running?
    medium_clone.run(solver: solver)

    assert_equal 2, solver.starts
  end

  def test_a_sidecar_that_does_not_start_is_an_error
    error = assert_raises(Hallmark::SolverError) { medium_clone.run(solver: sidecar("die")) }

    assert_includes error.message, "did not start"
    assert_includes error.message, "refusing to start"
  end

  def test_a_sidecar_with_another_protocol_is_an_error
    error = assert_raises(Hallmark::SolverError) { medium_clone.run(solver: sidecar("protocol-0")) }

    assert_includes error.message, "install-sidecar"
  end

  def test_an_alloy_error_is_an_error_not_an_unknown
    error = assert_raises(Hallmark::SolverError) { medium_clone.run(solver: sidecar("reject")) }

    assert_includes error.message, "Syntax error"
  end

  def test_close_stops_the_process
    solver = sidecar("ok")
    solver.call("version")
    pid = solver.pid
    solver.close

    refute_predicate solver, :running?
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  def test_java_command_caps_the_heap_and_names_the_solver
    Hallmark.configure do |config|
      config.sidecar_heap = 256
      config.sat_solver = "minisat"
    end
    command = Hallmark::Solver::Sidecar.new.command

    assert_includes command, "-Xmx256m"
    assert_equal %w[hallmark.solver.Sidecar --solver minisat], command.last(3)
    assert_includes command[command.index("-cp") + 1], Hallmark.configuration.alloy_jar
  end
end
