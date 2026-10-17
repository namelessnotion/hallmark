# typed: strict
# frozen_string_literal: true

require "open3"

module Hallmark
  # Solver backends. Each takes a ModelBuilder::Model in `check(model)` and
  # returns a Receipt with one verdict per check; a check that ran out of
  # time or memory comes back unknown, never as no counterexample.
  #
  #   Solver::CLI       `alloy exec` per analysis (one JVM start each)
  #   Solver::Sidecar   one long-lived JVM speaking JSON-RPC over stdio
  module Solver
    # The solver gave no answer in time; the process was stopped.
    class Timeout < SolverError; end

    # The sidecar exited without answering.
    class Crash < SolverError; end

    def self.build(config = Hallmark.configuration)
      case config.solver
      when :sidecar then Sidecar.new(config)
      else CLI.new(config)
      end
    end

    # Whether `java -version` runs and exits zero, for the backends'
    # `available?`.
    def self.java_runs?(java)
      _out, _err, status = Open3.capture3(java, "-version")
      status.success?
    rescue SystemCallError
      false
    end

    # Sends KILL; a process that is already gone is not an error.
    def self.kill(pid)
      Process.kill("KILL", pid)
      nil
    rescue Errno::ESRCH
      nil
    end
  end
end
