# frozen_string_literal: true

require "test_helper"
require "openssl"

# The shadow and sampled modes' settings, and hashed ids (phase 3 step 2,
# docs/adr/0004).
class LiveModesTest < Minitest::Test
  KEY = "k" * 32

  # A user and record with ids, as ActiveRecord's are.
  Person = Struct.new(:id, :name)
  Note = Struct.new(:id, :user)
  NotePolicy = Struct.new(:user, :record)

  def stamp(rule = "update?")
    Hallmark::Stamp.new(entry_point: "NotesController#update", policy: "NotePolicy", rule: rule, resource: "Note",
                        class_level: false, enforced: true, decision: "allow", logged_in: true, roles: [])
  end

  def test_the_sample_rate_follows_the_mode_unless_set
    config = Hallmark::Configuration.new

    assert_equal([1.0, 1.0, 0.01], %w[test shadow sampled].map { |mode| config.sample_rate_for(mode) })
    config.sample_rate = 0.25

    assert_in_delta 0.25, config.sample_rate_for("sampled")
    assert_raises(Hallmark::ConfigurationError) { config.sample_rate = 2 }
    assert_raises(Hallmark::ConfigurationError) { config.sample_rate = "all" }
  end

  def test_the_sample_rate_comes_from_the_environment
    with_env("HALLMARK_SAMPLE" => "0.1") do
      assert_in_delta 0.1, Hallmark::Configuration.new.sample_rate_for("sampled")
    end
  end

  # Every process of a deploy writes one run; test suites stay one run each.
  def test_a_live_run_is_named_by_the_deploys_revision
    Dir.mktmpdir do |root|
      with_env("HALLMARK_RUN" => nil, "HEROKU_SLUG_COMMIT" => nil, "GIT_SHA" => "abc-123") do
        config = Hallmark::Configuration.new

        assert_equal "abc_123", config.write_run("shadow", root)
        File.write(File.join(root, "REVISION"), "f3ef06a69\n")

        assert_equal "f3ef06a69", config.write_run("sampled", root)
        assert_match(/\A\d{8}T\d{9}Z\z/, config.write_run("test", root))
        config.run = "ci"

        assert_equal "ci", config.write_run("shadow", root)
      end
    end
  end

  def test_a_live_store_is_bounded_and_a_test_store_is_not
    config = Hallmark::Configuration.new

    assert_equal Hallmark::Configuration::LIVE_CAPACITY, config.stamp_store("shadow", Dir.pwd).capacity
    assert_nil config.stamp_store("test", Dir.pwd).capacity
  end

  def test_ids_need_a_live_mode_and_a_long_key
    config = Hallmark::Configuration.new
    config.ids = true

    assert_raises(Hallmark::ConfigurationError) { config.id_key_for("shadow") }
    config.id_key = KEY

    assert_equal KEY, config.id_key_for("sampled")
    assert_raises(Hallmark::ConfigurationError) { config.id_key_for("test") }
    config.ids = false

    assert_nil config.id_key_for("shadow")
  end

  # The first occurrence carries its example, hashed; the raw ids never
  # reach the sink.
  def test_a_stamp_is_written_once_with_its_hashed_example
    lines = []
    store = Hallmark::StampStore.new("unused", run: "r1", id_key: KEY, sink: ->(line) { lines << line })
    store.record(stamp, example: Hallmark::Example.new(user: "Person:1", record: "Note:7"))
    store.record(stamp, example: Hallmark::Example.new(user: "Person:2", record: "Note:8"))
    store.flush

    assert_equal 1, lines.size
    example = JSON.parse(lines.fetch(0)).fetch("example")

    assert_equal OpenSSL::HMAC.hexdigest("SHA256", KEY, "Person:1"), example.fetch("user")
    assert_nil example.fetch("tenant")
    refute_includes lines.fetch(0), "Person:1"
    set = Hallmark::StampSet.parse(lines)

    assert_equal [stamp], set.stamps
    assert_equal example.fetch("record"), set.examples.fetch(stamp).record
  end

  def test_a_store_without_a_key_writes_no_example
    lines = []
    store = Hallmark::StampStore.new("unused", run: "r1", sink: ->(line) { lines << line })
    store.record(stamp, example: Hallmark::Example.new(user: "Person:1"))
    store.flush

    refute_predicate store, :ids?
    refute_includes JSON.parse(lines.fetch(0)), "example"
  end

  def test_the_collectors_capture_ids_only_for_a_store_that_records_them
    mapping = Hallmark::Mapping.new.tap do |m|
      m.instance_eval do
        principal "LiveModesTest::Person"
        resource "LiveModesTest::Note", owner: :user
      end
    end
    ann = Person.new(1, "ann")
    note = Note.new(7, ann)
    lines = []
    store = Hallmark::StampStore.new("unused", run: "r1", id_key: KEY, sink: ->(line) { lines << line })
    Hallmark::Collectors.install!(mapping: mapping, store: store)
    begin
      Hallmark::Collectors.observe(policy: NotePolicy.new(ann, note), rule: :update?, record: note, enforced: true) do
        true
      end
    ensure
      Hallmark::Collectors.uninstall!
    end

    example = JSON.parse(lines.fetch(0)).fetch("example")

    assert_equal OpenSSL::HMAC.hexdigest("SHA256", KEY, "LiveModesTest::Note:7"), example.fetch("record")
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", KEY, "LiveModesTest::Person:1"), example.fetch("user")
  end

  def test_an_object_without_an_id_has_no_reference
    assert_nil Hallmark::Example.ref(Object.new)
    assert_nil Hallmark::Example.ref(Person.new(nil, "new"))
    assert_equal "LiveModesTest::Person:3", Hallmark::Example.ref(Person.new(3, "cy"))
  end
end
