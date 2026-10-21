# typed: strict
# frozen_string_literal: true

require "io/wait"

module Hallmark
  # `hallmark watch` (phase 3 step 3): a process outside the app that tails
  # the stamps live requests write (shadow and sampled modes), re-checks
  # only what they change, and reports what CI's baseline did not already
  # have. It never boots the app: the mapping names classes in strings and
  # the extractor reads source, as for `hallmark check`.
  #
  # Each batch of new lines is folded into the stamps the baseline was built
  # from, and inference runs again over all of them (it is Ruby over a few
  # hundred stamps). Only exposures whose digest (`Exposure#digest`) differs
  # from the last one checked, the baseline's first, go to the solver, in
  # one analysis of just those exposures; the mapping's facts do not depend
  # on which exposures are present.
  #
  # What counts as new: a counterexample on a check that was not failing in
  # the baseline or an earlier batch (one already failing is counted as
  # already known, even if its guard widened), an unchecked entry point or
  # drift the baseline does not list. A failing check that passes again is
  # reported once as no longer failing. An unknown verdict is printed and
  # retried at the next batch whose new stamps touch the exposure (its entry
  # point or one of its rules); it is never read as no counterexample.
  #
  #   watch = Watch.new(mapping: mapping, baseline: Baseline.load("baseline.json"),
  #                     source: Watch::FileTail.new("tmp/hallmark"), solver: Hallmark.solver,
  #                     mapping_digest: Baseline.digest_files(["config/hallmark.rb"]))
  #   watch.run(once: true) # => 1 on any new finding
  class Watch
    # Everything new since the watch started, for its SARIF log (`Sarif`
    # reads it as it reads a report).
    Log = Struct.new(:findings, :unchecked, :drift, :lints, :extractor, keyword_init: true)

    attr_reader :events, :log, :solver, :source

    def initialize(mapping:, baseline:, source:, solver:, mapping_digest:, extractor: nil, out: $stdout, err: $stderr,
                   json: false, sarif: nil, sarif_fallback: nil, on_finding: Hallmark.configuration.on_finding)
      @mapping = mapping
      mapping.validate!
      @baseline = baseline
      @source = source
      @solver = solver
      @extractor = extractor
      @out = out
      @err = err
      @json = json
      @sarif = sarif
      @sarif_fallback = sarif_fallback
      @on_finding = on_finding
      @events = []
      @log = Log.new(findings: [], unchecked: [], drift: [], lints: [], extractor: extractor)
      @started = false
      @stamps = Stamps.new(baseline.stamp_set, err: err)
      seed(baseline, baseline.stale_reasons(mapping_digest: mapping_digest))
    end

    # Reads what the source has, folds it in and checks the exposures it
    # changed; nil when there was nothing to do (no new line after the first
    # batch, which always runs so a stale baseline or changed code is
    # checked at once).
    def poll
      lines = @source.poll
      return nil if lines.empty? && @started

      @started = true
      fresh = @stamps.fold(lines)
      inference = Inference.new(@mapping, stamp_set, extractor: @extractor)
      changed = inference.exposures.select { |exposure| changed?(exposure, fresh) }
      batch = Batch.new(lines: lines.size, stamps: fresh.size, checks: changed.size, events: [], known: 0, none: 0)
      verdicts(batch, changed, check(changed))
      batch.events.concat(unchecked_events(inference) + drift_events(inference))
      report(batch)
      batch
    end

    # `once`: one batch over everything available, then the exit status
    # over what was new (1 on a finding, unchecked entry point or drift,
    # else 2 on an unknown, else 0). Otherwise batches every `interval`
    # seconds until SIGINT or SIGTERM, then 0. Closes the solver either way.
    def run(once: false, interval: 2.0)
      header
      if once
        poll
        return exit_code
      end

      until_stopped(interval) { poll_safely }
      0
    ensure
      @solver.close
    end

    def exit_code
      return 1 if @events.any?(&:failure?)

      @events.any? { |event| event.type == :unknown } ? 2 : 0
    end

    # The stamps folded in so far, baseline and live.
    def stamp_set = @stamps.set

    private

    # Starts from the baseline's lines, digests and verdicts. A stale
    # baseline (another mapping, scope or version) keeps only which checks
    # were failing, so they are not reported as new, and every exposure is
    # checked once.
    def seed(baseline, stale)
      @digests = stale.empty? ? baseline.checks.to_h { |check| [check.name, check.digest] } : {}
      @unknown = Set.new(baseline.checks.select(&:unknown?).map(&:name))
      @failing = Set.new(baseline.failing.map(&:name))
      @known_unchecked = Set.new(baseline.unchecked)
      @known_drift = Set.new(baseline.drift)
      return if stale.empty?

      @err.puts "hallmark watch: the baseline is stale (#{stale.join("; ")}); checking every exposure once"
    end

    def changed?(exposure, fresh)
      name = exposure.check_name
      return true unless @digests[name] == exposure.digest(@mapping)

      @unknown.include?(name) && fresh.any? do |stamp|
        stamp.entry_point == exposure.action || (exposure.rules || []).include?(stamp.rule_key)
      end
    end

    # The changed exposures alone, checked against the same mapping.
    def check(changed)
      return nil if changed.empty?

      analysis = Analysis.new("watch", mapping: @mapping)
      changed.each do |exposure|
        analysis.add_exposure(action: exposure.action, op: exposure.op, resource: exposure.resource,
                              guard: exposure.guard, basis: exposure.basis, locations: exposure.locations,
                              rules: exposure.rules)
      end
      analysis.validate!.run(solver: @solver)
    end

    # Files each verdict, recording the digest it was given for.
    def verdicts(batch, changed, report)
      return unless report

      digests = changed.to_h { |exposure| [exposure.check_name, exposure.digest(@mapping)] }
      report.findings.each { |finding| found(batch, finding, digests) }
      report.verified.each { |exposure| passed(batch, exposure, digests) }
      report.unknown.each do |item|
        name = item.exposure.check_name
        @digests[name] = digests.fetch(name)
        @unknown << name
        batch.events << Event.unknown(item)
      end
    end

    def found(batch, finding, digests)
      name = finding.exposure.check_name
      @digests[name] = digests.fetch(name)
      @unknown.delete(name)
      if @failing.include?(name)
        batch.known += 1
        return
      end

      @failing << name
      @log.findings << finding
      batch.events << Event.finding(finding, @stamps.example_for(finding.exposure))
    end

    def passed(batch, exposure, digests)
      name = exposure.check_name
      @digests[name] = digests.fetch(name)
      @unknown.delete(name)
      batch.none += 1
      batch.events << Event.resolved(exposure) if @failing.delete?(name)
    end

    def unchecked_events(inference)
      inference.unchecked.reject { |entry_point| @known_unchecked.include?(entry_point) }.map do |entry_point|
        @known_unchecked << entry_point
        @log.unchecked << entry_point
        Event.unchecked(entry_point)
      end
    end

    def drift_events(inference)
      inference.drift.reject { |item| @known_drift.include?(item.key) }.map do |item|
        @known_drift << item.key
        @log.drift << item
        Event.drift(item)
      end
    end

    # Prints the batch's events and summary, calls `on_finding`, and
    # rewrites the SARIF log.
    def report(batch)
      batch.events.each { |event| emit(event) }
      @out.puts batch.summary unless @json
      @out.flush
      write_sarif
    end

    def emit(event)
      @events << event
      @json ? @out.puts(event.to_json) : @out.puts(event.lines)
      notify(event) unless event.type == :unknown
    end

    def notify(event)
      callback = @on_finding
      callback&.call(event)
    rescue StandardError => e
      @err.puts "hallmark watch: on_finding raised #{e.class}: #{e.message}"
    end

    def write_sarif
      path = @sarif
      File.write(path, Sarif.new([@log], fallback: @sarif_fallback).to_json) if path
    end

    def header
      return if @json

      baseline = @baseline
      run = baseline.run ? "run #{baseline.run}" : "an unnamed run"
      @out.puts "Hallmark #{VERSION} watch, Alloy #{ALLOY_VERSION}, scope #{Hallmark.configuration.scope}; " \
                "baseline of #{run}: #{baseline.checks.size} checks, " \
                "#{baseline.failing.size} failing; watching #{@source.description}"
    end

    # A batch that fails (a guard the mapping rejects, a solver that cannot
    # start) is warned about and the watch goes on with the next.
    def poll_safely
      poll
    rescue Error => e
      @err.puts "hallmark watch: #{e.message}"
    end

    # Runs the block until SIGINT or SIGTERM, waiting `interval` seconds
    # between runs unless the source waits itself (a blocking read).
    def until_stopped(interval)
      reader, writer = IO.pipe
      signals = []
      previous = %w[INT TERM].to_h do |signal|
        [signal, trap(signal) do
          signals << signal
          writer.write_nonblock(".", exception: false)
        end]
      end
      begin
        while signals.empty?
          yield
          reader.wait_readable(interval) unless @source.blocking?
        end
      ensure
        previous.each { |signal, handler| trap(signal, handler) }
        [reader, writer].each(&:close)
      end
    end
  end
end

require_relative "watch/event"
require_relative "watch/stamps"
require_relative "watch/file_tail"
require_relative "watch/redis_tail"
