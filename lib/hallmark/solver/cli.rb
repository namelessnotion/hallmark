# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module Hallmark
  module Solver
    # Runs models through the Alloy 6.2 command line (`alloy exec`). This is
    # the phase 0 backend: one JVM start per run. Phase 1 replaces it with a
    # long-lived sidecar behind the same `check(model)` interface.
    class CLI
      attr_reader :jar, :java, :timeout, :solver

      def initialize(config = Hallmark.configuration)
        @jar = config.alloy_jar
        @java = config.java
        @timeout = config.timeout
        @solver = config.solver
      end

      def available?
        File.file?(jar) && java_runs?
      end

      def check(model)
        unless File.file?(jar)
          raise SolverError, "Alloy jar not found at #{jar}; run `hallmark install-alloy` or set HALLMARK_ALLOY_JAR"
        end

        Dir.mktmpdir("hallmark") do |dir|
          FileUtils.cp(CATALOG_PATH, File.join(dir, "catalog.als"))
          model_path = File.join(dir, "model.als")
          File.write(model_path, model.source)
          output = File.join(dir, "out")

          stdout, stderr, status = run(command(model_path, output))
          receipt_path = File.join(output, "receipt.json")
          unless status.success? && File.file?(receipt_path)
            details = [stderr, stdout].join("\n").lines.reject { |line| line.start_with?("Picked up") }.join.strip
            raise SolverError, "Alloy exited with status #{status.exitstatus}:\n#{details}"
          end

          Receipt.load(output)
        end
      end

      private

      def command(model_path, output)
        [java, "-jar", jar, "exec", "--quiet", "--force", "--type", "xml",
         "--solver", solver, "--output", output, "--command", "*", model_path]
      end

      def run(cmd)
        Open3.popen3(*cmd) do |stdin, stdout, stderr, wait|
          stdin.close
          out = Thread.new { stdout.read }
          err = Thread.new { stderr.read }
          unless wait.join(timeout)
            begin
              Process.kill("KILL", wait.pid)
            rescue Errno::ESRCH
              nil
            end
            wait.join
            raise SolverError, "Alloy did not finish within #{timeout}s; lower the scope or raise HALLMARK_TIMEOUT"
          end
          [out.value, err.value, wait.value]
        end
      end

      def java_runs?
        _out, _err, status = Open3.capture3(java, "-version")
        status.success?
      rescue SystemCallError
        false
      end
    end
  end
end
