# typed: strict
# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module Hallmark
  module Solver
    # Runs models through the Alloy 6.2 command line (`alloy exec`): one JVM
    # start per analysis. The phase 0 backend, kept as the default and as a
    # cross-check for Solver::Sidecar, which has the same `check(model)`.
    # `c.timeout` bounds the whole run; when it runs out every check is
    # unknown.
    class CLI
      attr_reader :jar, :java, :timeout, :solver

      def initialize(config = Hallmark.configuration)
        @jar = config.alloy_jar
        @java = config.java
        @timeout = config.timeout
        @solver = config.sat_solver
      end

      def available?
        File.file?(jar) && Solver.java_runs?(java)
      end

      def check(model)
        Dir.mktmpdir("hallmark-out") { |output| solve_into(model, output) }
      rescue Timeout
        Receipt.unknown(model.checks.keys, "the Alloy run timed out after #{timeout} s")
      end

      # Nothing to stop: each run is its own process.
      def close; end

      # Solves `model` and leaves Alloy's raw output (receipt.json plus one
      # XML instance per counterexample) in `output`, which Alloy recreates.
      # Used by `check`, and by `rake fixtures:regenerate` to refresh the
      # captured run the unit tests decode.
      def solve_into(model, output)
        unless File.file?(jar)
          raise SolverError, "Alloy jar not found at #{jar}; run `hallmark install-alloy` or set HALLMARK_ALLOY_JAR"
        end

        Dir.mktmpdir("hallmark") do |dir|
          FileUtils.cp(CATALOG_PATH, File.join(dir, "catalog.als"))
          model_path = File.join(dir, "model.als")
          File.write(model_path, model.source)

          stdout, stderr, status = run(command(model_path, output))
          unless status.success? && File.file?(File.join(output, "receipt.json"))
            details = [stderr, stdout].join("\n").lines.reject { |line| line.start_with?("Picked up") }.join.strip
            raise SolverError, "Alloy exited with status #{status.exitstatus}:\n#{details}"
          end
        end

        Receipt.load(output)
      end

      private

      def command(model_path, output)
        [java, "-jar", jar, "exec", "--quiet", "--force", "--type", "xml",
         "--solver", solver, "--output", output, "--command", "*", model_path]
      end

      def run(cmd)
        Open3.popen3(*cmd) do |stdin, stdout, stderr, wait|
          stdin.close
          out = Thread.new { drain(stdout) }
          err = Thread.new { drain(stderr) }
          unless wait.join(timeout)
            Solver.kill(wait.pid)
            wait.join
            raise Timeout, "Alloy did not finish within #{timeout}s; lower the scope or raise HALLMARK_TIMEOUT"
          end
          [out.value, err.value, wait.value]
        end
      end

      # A pipe closed under the reader (after a timeout kill) reads as empty.
      def drain(pipe)
        pipe.read
      rescue IOError
        ""
      end
    end
  end
end
