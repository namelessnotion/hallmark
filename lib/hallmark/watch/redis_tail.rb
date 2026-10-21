# typed: strict
# frozen_string_literal: true

module Hallmark
  class Watch
    # Tails the Redis stream `Sinks::RedisStream` writes (entries with the
    # fields `run` and `line`), keeping the lines of one run, or of every run
    # with `all_runs:`. It starts after the stream's last entry, or at its
    # first with `from_start:`, and reads with XREAD, waiting up to `block`
    # milliseconds for an entry when given one. The client is redis-rb
    # (`xread`, `xrevrange`) or redis-client (`call`, `blocking_call`);
    # `RedisTail.connect` makes one from a URL with whichever gem is
    # installed, and Hallmark depends on neither.
    class RedisTail
      # Entries asked for per XREAD; a full answer is followed by another
      # read at once.
      COUNT = 1000

      attr_reader :client, :stream, :run

      # A client for `url` from the redis-client gem, else the redis gem.
      def self.connect(url)
        begin
          require "redis-client"
          return Object.const_get(:RedisClient).new(url: url)
        rescue LoadError
          nil
        end
        begin
          require "redis"
          Object.const_get(:Redis).new(url: url)
        rescue LoadError
          raise ConfigurationError, "watching a Redis stream needs the redis-client or redis gem in the bundle " \
                                    "`hallmark watch` runs with; Hallmark depends on neither"
        end
      end

      def initialize(client, stream: Sinks::RedisStream::DEFAULT_STREAM, run: nil, all_runs: false,
                     from_start: false, block: nil)
        unless client.respond_to?(:xread) || client.respond_to?(:call)
          raise ConfigurationError,
                "a Redis tail needs a redis-rb or redis-client connection, not a #{client.class.name}"
        end
        raise ConfigurationError, "watching a Redis stream needs the run to watch (--run), or --all-runs" if
          run.nil? && !all_runs

        @client = client
        @stream = stream.to_s
        @run = run
        @all_runs = all_runs
        @block = block
        @last_id = from_start ? "0-0" : nil
      end

      def blocking? = !@block.nil?

      def description = "Redis stream #{@stream}#{@all_runs ? " (every run)" : " (run #{@run})"}"

      # The lines of the run added since the last poll; waits up to `block`
      # milliseconds for the first entry.
      def poll
        @last_id ||= last_entry_id
        lines = []
        wait = @block
        loop do
          entries = read(wait)
          wait = nil
          entries.each do |id, fields|
            @last_id = id
            line = fields["line"]
            lines << line.to_s if line && (@all_runs || fields["run"] == @run)
          end
          break if entries.size < COUNT
        end
        lines
      end

      private

      # [[id, fields]], oldest first; empty when the wait ran out.
      def read(block)
        last = @last_id.to_s
        return entries(client.xread(@stream, last, count: COUNT, block: block)) if client.respond_to?(:xread)

        args = ["XREAD", "COUNT", COUNT.to_s, *(["BLOCK", block.to_s] if block), "STREAMS", @stream, last]
        if block && client.respond_to?(:blocking_call)
          entries(client.blocking_call((block / 1000.0) + 1, *args))
        else
          entries(client.call(*args))
        end
      end

      # The id of the stream's newest entry, so the tail starts after it;
      # "0-0" for an empty stream.
      def last_entry_id
        result = if client.respond_to?(:xrevrange)
                   client.xrevrange(@stream, "+", "-", count: 1)
                 else
                   client.call("XREVRANGE", @stream, "+", "-", "COUNT", "1")
                 end
        newest = Array(result).first
        newest ? newest[0].to_s : "0-0"
      end

      # XREAD answers nil on a timeout, a Hash from stream to entries
      # (redis-rb, RESP3) or an Array of [stream, entries] (RESP2); fields
      # come as a Hash or a flat [name, value, ...] Array.
      def entries(result)
        streams = result.is_a?(Hash) ? result.to_a : Array(result)
        streams.flat_map { |(_name, items)| Array(items) }.map { |(id, fields)| [id.to_s, field_hash(fields)] }
      end

      def field_hash(fields)
        return fields.transform_keys(&:to_s) if fields.is_a?(Hash)

        Array(fields).each_slice(2).to_h { |name, value| [name.to_s, value] }
      end
    end
  end
end
