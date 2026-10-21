# typed: strict
# frozen_string_literal: true

require "fileutils"

module Hallmark
  # Where a StampStore's flusher thread writes each new line (a stamp, an
  # unchecked request or a route, as JSON). A sink is any object with
  # `write(line, run)`; `flush` and `after_fork` are optional. Writes run on
  # the flusher thread, never on a request, so a sink may block on the
  # network. `Hallmark.configure { |c| c.sink = ... }` picks one; the
  # default is `Sinks::File` under `c.stamps`.
  module Sinks
    # One JSONL file per process and run, `<dir>/stamps-<run>-<pid>.jsonl`,
    # which `StampSet.load` reads. The directory gets a `.gitignore` so
    # stamps are never committed.
    class File
      attr_reader :dir

      def initialize(dir)
        @dir = dir.to_s
        @file = nil
      end

      def path(run) = ::File.join(dir, "stamps-#{run}-#{Process.pid}.jsonl")

      def write(line, run) = (@file ||= open_file(run)).puts(line)

      def flush = @file&.flush

      # The parent's file is the parent's: a forked child writes its own,
      # and drops (never closes) the inherited handle, whose buffer the
      # parent still flushes.
      def after_fork = @file = nil

      private

      def open_file(run)
        FileUtils.mkdir_p(dir)
        ignore = ::File.join(dir, ".gitignore")
        ::File.write(ignore, "*\n") unless ::File.exist?(ignore)
        ::File.open(path(run), "a")
      end
    end

    # A Redis stream, through the client the app passes in, so Hallmark
    # depends on no Redis gem: redis-rb (`xadd`) or redis-client (`call`).
    # Each entry has the fields `run` and `line`; the stream is trimmed to
    # about `maxlen` entries. Deduplication happens per process before the
    # write, so the stream holds each process's new stamps.
    class RedisStream
      DEFAULT_STREAM = "hallmark:stamps"
      DEFAULT_MAXLEN = 100_000

      attr_reader :client, :stream, :maxlen

      def initialize(client, stream: DEFAULT_STREAM, maxlen: DEFAULT_MAXLEN)
        unless client.respond_to?(:xadd) || client.respond_to?(:call)
          raise ConfigurationError, "a Redis stream sink needs a redis-rb or redis-client connection, " \
                                    "not a #{client.class.name}"
        end

        @client = client
        @stream = stream.to_s
        @maxlen = maxlen
      end

      def write(line, run)
        if client.respond_to?(:xadd)
          client.xadd(stream, { "run" => run, "line" => line }, maxlen: maxlen, approximate: true)
        else
          client.call("XADD", stream, "MAXLEN", "~", maxlen.to_s, "*", "run", run, "line", line)
        end
      end
    end

    # Any callable, given the line, or the line and the run.
    class Callable
      def initialize(callable)
        @callable = callable
      end

      def write(line, run)
        arity = @callable.respond_to?(:arity) ? @callable.arity : 1
        arity == 1 ? @callable.call(line) : @callable.call(line, run)
      end
    end

    # A sink from what `c.sink =` was given: nil for the default file, a
    # sink, or a callable.
    def self.build(value)
      return nil if value.nil?
      return value if value.respond_to?(:write)
      return Callable.new(value) if value.respond_to?(:call)

      raise ConfigurationError, "a sink responds to `write(line, run)` or `call(line)`; got a #{value.class.name}"
    end
  end
end
