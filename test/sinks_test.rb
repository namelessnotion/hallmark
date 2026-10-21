# frozen_string_literal: true

require "test_helper"

# Where the stamp store's flusher writes (phase 3 step 2).
class SinksTest < Minitest::Test
  # redis-rb's interface.
  class XaddClient
    attr_reader :entries

    def initialize = @entries = []

    def xadd(stream, fields, maxlen:, approximate:) = @entries << [stream, fields, maxlen, approximate]
  end

  # redis-client's interface.
  class CallClient
    attr_reader :commands

    def initialize = @commands = []

    def call(*command) = @commands << command
  end

  def stamp(rule = "update?")
    Hallmark::Stamp.new(entry_point: "LinksController#update", policy: "LinkPolicy", rule: rule, resource: "Link",
                        class_level: false, enforced: true, decision: "allow", logged_in: true, roles: [])
  end

  def test_the_default_sink_is_one_file_per_run_and_process
    Dir.mktmpdir do |dir|
      store = Hallmark::StampStore.new(dir, run: "r1")
      store.record(stamp)
      store.flush

      assert_instance_of Hallmark::Sinks::File, store.sink
      assert_equal File.join(dir, "stamps-r1-#{Process.pid}.jsonl"), store.path
      assert_equal [stamp], Hallmark::StampSet.load(dir).stamps
    end
  end

  def test_a_redis_stream_gets_the_run_and_the_line
    client = XaddClient.new
    Hallmark::Sinks::RedisStream.new(client, maxlen: 50).write("{}", "r1")

    assert_equal [["hallmark:stamps", { "run" => "r1", "line" => "{}" }, 50, true]], client.entries
  end

  def test_a_redis_client_connection_is_called_with_xadd
    client = CallClient.new
    Hallmark::Sinks::RedisStream.new(client, stream: "app:hallmark").write("{}", "r1")

    assert_equal [["XADD", "app:hallmark", "MAXLEN", "~", "100000", "*", "run", "r1", "line", "{}"]], client.commands
  end

  def test_a_redis_stream_needs_a_connection
    assert_raises(Hallmark::ConfigurationError) { Hallmark::Sinks::RedisStream.new(Object.new) }
  end

  def test_a_callable_gets_the_line_and_maybe_the_run
    lines = []
    Hallmark::Sinks.build(->(line) { lines << [line] }).write("a", "r1")
    Hallmark::Sinks.build(->(line, run) { lines << [line, run] }).write("b", "r1")

    assert_equal [["a"], %w[b r1]], lines
    assert_raises(Hallmark::ConfigurationError) { Hallmark::Sinks.build(42) }
  end

  def test_the_store_writes_each_new_line_through_its_sink
    lines = []
    store = Hallmark::StampStore.new("unused", run: "r1", sink: ->(line, run) { lines << [JSON.parse(line), run] })
    2.times { store.record(stamp) }
    store.record(Hallmark::Unchecked.new(entry_point: "PagesController#home"))
    store.flush

    assert_equal([%w[stamp r1], %w[unchecked r1]], lines.map { |data, run| [data.fetch("type"), run] })
    assert_nil store.path
  end

  # A sink on the network fails now and then; the flusher must outlive it.
  def test_a_failing_sink_loses_the_line_and_carries_on
    written = []
    sink = lambda do |line|
      raise IOError, "connection reset" if line.include?("edit?")

      written << line
    end
    store = Hallmark::StampStore.new("unused", run: "r1", sink: sink)
    _, err = capture_io do
      store.record(stamp("edit?"))
      store.record(stamp("update?"))
      store.flush
    end

    assert_equal 1, store.failed
    assert_equal 1, written.size
    assert_match(/stamp sink failed: IOError: connection reset/, err)
  end
end
