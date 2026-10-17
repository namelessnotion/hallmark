# typed: strict
# frozen_string_literal: true

require "io/wait"
require "open3"

module Hallmark
  module Solver
    # One sidecar process seen as a line-oriented pipe: lines in on stdin,
    # lines out on stdout read against a deadline, and the tail of stderr
    # kept for error messages. Solver::Sidecar owns the protocol and decides
    # when to start, stop and replace one.
    class ChildProcess
      # Bytes of stderr kept for error messages
      STDERR_KEPT = 8192

      def self.spawn(command)
        stdin, stdout, stderr, wait = popen(command)
        new(stdin, stdout, stderr, wait)
      end

      # T.untyped in the RBI so Sorbet accepts the splat.
      def self.popen(command) = Open3.popen3(*command)

      def initialize(stdin, stdout, stderr, wait)
        @stdin = stdin
        @stdout = stdout
        @wait = wait
        @output = String.new(encoding: Encoding::BINARY)
        @errors = String.new(encoding: Encoding::BINARY)
        # Draining stderr also stops a chatty JVM from filling the pipe and blocking.
        @reader = Thread.new { drain(stderr) }
      end

      def pid = @wait.pid

      def write_line(line)
        @stdin.write(line, "\n")
        @stdin.flush
      rescue IOError, SystemCallError
        raise crash
      end

      # The next line from stdout, or nil if none came by `deadline` (a
      # monotonic clock reading). Raises Crash when the process exits.
      def read_line(deadline)
        loop do
          if (newline = @output.index("\n"))
            return @output.slice!(0..newline)&.force_encoding(Encoding::UTF_8)
          end

          remaining = deadline - ChildProcess.now
          return nil unless remaining.positive?
          next unless @stdout.wait_readable(remaining)

          begin
            @output << @stdout.read_nonblock(65_536)
          rescue IO::WaitReadable
            next
          rescue IOError
            raise crash
          end
        end
      end

      # Waits up to `seconds` for the process to exit on its own, then kills it.
      def finish(seconds = 2)
        @stdin.close unless @stdin.closed?
        kill unless @wait.join(seconds)
        reap
      end

      def kill
        Solver.kill(pid)
        reap
      end

      # The exit, as an error: status and the last lines of stderr.
      def crash
        status = reap
        message = "the sidecar exited#{" with status #{status.exitstatus}" if status&.exitstatus}"
        tail = errors_tail
        Crash.new(tail.empty? ? message : "#{message} (#{tail})")
      end

      # JVM chatter (JAVA_TOOL_OPTIONS notices, native-access warnings) is
      # left out.
      def errors_tail(lines = 5)
        text = @errors.dup.force_encoding(Encoding::UTF_8).scrub
        text.lines.reject { |line| line.strip.empty? || line.start_with?("Picked up", "WARNING:") }
            .last(lines).join.strip
      end

      def self.now = Float(Process.clock_gettime(Process::CLOCK_MONOTONIC))

      private

      def reap
        status = @wait.value
        [@stdin, @stdout].each { |io| io.close unless io.closed? }
        @reader.join(1)
        status
      end

      def drain(stderr)
        loop do
          @errors << stderr.readpartial(4096)
          @errors.slice!(0, @errors.bytesize - STDERR_KEPT) if @errors.bytesize > STDERR_KEPT
        end
      rescue IOError
        stderr.close unless stderr.closed?
      end
    end
  end
end
