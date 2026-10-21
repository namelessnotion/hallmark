# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class StampStoreTest < Minitest::Test
  def stamp(rule = "update?")
    Hallmark::Stamp.new(entry_point: "LinksController#update", policy: "LinkPolicy", rule: rule, resource: "Link",
                        class_level: false, enforced: true, decision: "allow", logged_in: true, roles: [])
  end

  def test_writes_deduplicated_stamps_as_jsonl_off_the_calling_thread
    Dir.mktmpdir do |dir|
      store = Hallmark::StampStore.new(File.join(dir, "tmp", "hallmark"), run: "r1")
      3.times { store.record(stamp) }
      store.record(stamp("edit?"))
      store.record(Hallmark::Unchecked.new(entry_point: "PagesController#home"))
      store.flush

      lines = File.readlines(store.path, chomp: true)
      assert_equal 3, lines.size
      assert_equal "stamp", JSON.parse(lines.first).fetch("type")
      assert_equal "*\n", File.read(File.join(dir, "tmp", "hallmark", ".gitignore"))
      assert_match(/stamps-r1-#{Process.pid}\.jsonl\z/o, store.path)
    end
  end

  def test_round_trips_through_a_stamp_set
    Dir.mktmpdir do |dir|
      store = Hallmark::StampStore.new(dir, run: "r1")
      store.record(stamp)
      home = Hallmark::Unchecked.new(entry_point: "PagesController#home", status: 302, verb: "GET")
      2.times { store.record(home) }
      store.flush

      set = Hallmark::StampSet.load(dir)
      assert_equal [stamp], set.stamps
      assert_equal [home], set.unchecked
    end
  end

  # Lines written before Oct 17, 2026 carry no status or verb; they parse
  # with nil, so Inference fails them as it did then.
  def test_an_unchecked_line_without_status_or_verb_still_parses
    set = Hallmark::StampSet.parse(['{"type":"unchecked","entry_point":"PagesController#home"}'])

    assert_equal [Hallmark::Unchecked.new(entry_point: "PagesController#home")], set.unchecked
    assert_nil set.unchecked.fetch(0).status
    assert_nil set.unchecked.fetch(0).verb
  end

  # Writes a stamp file for one rule with the given mtime (seconds since
  # the epoch), so tests order runs without sleeping.
  def write_stamps(dir, name, rule, mtime)
    file = File.join(dir, name)
    File.write(file, "#{stamp(rule).to_json_line}\n")
    File.utime(mtime, mtime, file)
    file
  end

  T0 = Time.utc(2026, 10, 17).to_i

  # Parallel test workers write one file each per run; a directory read
  # takes every file of the latest run and ignores older runs.
  def test_a_directory_reads_every_file_of_the_latest_run
    Dir.mktmpdir do |dir|
      write_stamps(dir, "stamps-20261014T000000000Z-1.jsonl", "old?", T0)
      write_stamps(dir, "stamps-20261015T000000000Z-1.jsonl", "edit?", T0 + 10)
      write_stamps(dir, "stamps-20261015T000000000Z-2.jsonl", "update?", T0 + 20)
      File.write(File.join(dir, "notes.jsonl"), "not a stamp file\n")

      assert_equal %w[edit? update?], Hallmark::StampSet.load(dir).stamps.map(&:rule)
    end
  end

  # The latest run is the one written last, not the greatest id: a fixed
  # HALLMARK_RUN such as "ci" sorts after every timestamp as a string.
  def test_a_letter_named_old_run_does_not_outrank_a_newer_timestamp_run
    Dir.mktmpdir do |dir|
      write_stamps(dir, "stamps-ci-1.jsonl", "old?", T0)
      newer = [write_stamps(dir, "stamps-20261017T000000000Z-1.jsonl", "edit?", T0 + 10),
               write_stamps(dir, "stamps-20261017T000000000Z-2.jsonl", "update?", T0 + 20)]

      assert_equal newer, Hallmark::StampSet.files(dir)
      assert_equal %w[edit? update?], Hallmark::StampSet.load(dir).stamps.map(&:rule)
    end
  end

  # Numeric ids compare as strings too ("9" > "10"); mtimes do not.
  def test_numeric_run_ids_do_not_order_runs
    Dir.mktmpdir do |dir|
      write_stamps(dir, "stamps-9-1.jsonl", "old?", T0)
      write_stamps(dir, "stamps-10-1.jsonl", "update?", T0 + 10)

      assert_equal %w[update?], Hallmark::StampSet.load(dir).stamps.map(&:rule)
    end
  end

  # A run counts by its newest file: one worker of the newer run may have
  # finished before the old run's last write.
  def test_a_run_counts_by_its_newest_file
    Dir.mktmpdir do |dir|
      write_stamps(dir, "stamps-a-1.jsonl", "edit?", T0)
      write_stamps(dir, "stamps-z-1.jsonl", "old?", T0 + 10)
      write_stamps(dir, "stamps-a-2.jsonl", "update?", T0 + 20)

      assert_equal %w[edit? update?], Hallmark::StampSet.load(dir).stamps.map(&:rule)
    end
  end

  def test_run_names_a_run_explicitly
    Dir.mktmpdir do |dir|
      old = write_stamps(dir, "stamps-ci-1.jsonl", "old?", T0)
      write_stamps(dir, "stamps-20261017T000000000Z-1.jsonl", "update?", T0 + 10)

      assert_equal [old], Hallmark::StampSet.files(dir, run: "ci")
      assert_equal %w[old?], Hallmark::StampSet.load(dir, run: "ci").stamps.map(&:rule)
      assert_empty Hallmark::StampSet.files(dir, run: "missing")
    end
  end

  # A file deleted between the directory listing and its mtime is skipped.
  def test_a_vanished_file_does_not_count
    Dir.mktmpdir do |dir|
      present = write_stamps(dir, "stamps-a-1.jsonl", "update?", T0)
      runs = { "z" => [File.join(dir, "stamps-z-1.jsonl")], "a" => [present], nil => [File.join(dir, "x.jsonl")] }

      assert_equal "a", Hallmark::StampSet.send(:latest, runs)
    end
  end

  def test_equal_mtimes_fall_back_to_the_run_id
    Dir.mktmpdir do |dir|
      write_stamps(dir, "stamps-a-1.jsonl", "old?", T0)
      write_stamps(dir, "stamps-b-1.jsonl", "update?", T0)

      assert_equal %w[update?], Hallmark::StampSet.load(dir).stamps.map(&:rule)
    end
  end

  def test_an_empty_directory_is_an_error
    Dir.mktmpdir do |dir|
      error = assert_raises(Hallmark::Error) { Hallmark::StampSet.load(dir) }
      assert_match(/no stamps found/, error.message)
    end
  end

  def test_run_ids_cannot_contain_the_separator
    assert_raises(Hallmark::ConfigurationError) { Hallmark::StampStore.new("tmp", run: "2026-10-15") }
  end

  # In production modes the queue is bounded: a full queue drops and counts
  # rather than make the request wait or the queue grow.
  def test_a_store_with_a_capacity_drops_events_when_full
    Dir.mktmpdir do |dir|
      store = Hallmark::StampStore.new(dir, run: "r1", capacity: 2)
      # No flusher, so nothing leaves the queue.
      store.stub(:start, nil) { 3.times { |i| store.record(stamp("rule#{i}?")) } }

      assert_equal 1, store.dropped
    end
  end

  def test_without_a_capacity_nothing_is_dropped
    Dir.mktmpdir do |dir|
      store = Hallmark::StampStore.new(dir, run: "r1")
      store.stub(:start, nil) { 3.times { |i| store.record(stamp("rule#{i}?")) } }

      assert_equal 0, store.dropped
    end
  end

  def test_a_capacity_is_a_positive_integer
    assert_raises(Hallmark::ConfigurationError) { Hallmark::StampStore.new("tmp", run: "r1", capacity: 0) }
  end
end
