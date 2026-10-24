# typed: strict

module Hallmark
  class Watch
    # What `hallmark watch` reads lines from: Watch::FileTail or Watch::RedisTail
    Source = T.type_alias { T.any(FileTail, RedisTail) }

    # A solver backend: anything with `check(model)` and `close`
    Solver = T.type_alias { T.untyped }

    class Event
      # :finding, :unchecked, :drift, :resolved or :unknown
      sig { returns(Symbol) }
      def type; end

      sig { returns(T::Hash[String, T.untyped]) }
      def data; end

      sig { returns(T::Array[String]) }
      def lines; end

      sig { params(type: Symbol, data: T::Hash[String, T.untyped], lines: T::Array[String]).void }
      def initialize(type:, data:, lines:); end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h; end

      sig { params(args: T.untyped).returns(String) }
      def to_json(*args); end

      # A finding, unchecked entry point or drift: what fails `--once`
      sig { returns(T::Boolean) }
      def failure?; end

      sig { params(finding: Finding, example: T.nilable(Example)).returns(Event) }
      def self.finding(finding, example); end

      sig { params(exposure: AnyExposure).returns(Event) }
      def self.resolved(exposure); end

      sig { params(item: Report::Unknown).returns(Event) }
      def self.unknown(item); end

      sig { params(entry_point: String).returns(Event) }
      def self.unchecked(entry_point); end

      sig { params(item: Drift).returns(Event) }
      def self.drift(item); end

      sig { params(item: StaleAccess).returns(Event) }
      def self.stale(item); end

      sig { params(exposure: AnyExposure).returns(T::Hash[String, String]) }
      def self.exposure_data(exposure); end

      sig { params(example: Example).returns(String) }
      def self.example_line(example); end
    end

    class Log
      sig { returns(T::Array[Finding]) }
      def findings; end

      sig { returns(T::Array[String]) }
      def unchecked; end

      sig { returns(T::Array[Drift]) }
      def drift; end

      sig { returns(T::Array[StaleAccess]) }
      def stale_access; end

      # Always empty: policy-DSL hazards are CI's to report
      sig { returns(T::Array[Extractor::DeclarativeTranslator::Lint]) }
      def lints; end

      sig { returns(T.nilable(Extractor)) }
      def extractor; end

      sig do
        params(findings: T::Array[Finding], unchecked: T::Array[String], drift: T::Array[Drift],
               stale_access: T::Array[StaleAccess], lints: T::Array[Extractor::DeclarativeTranslator::Lint],
               extractor: T.nilable(Extractor)).void
      end
      def initialize(findings:, unchecked:, drift:, stale_access:, lints:, extractor:); end
    end

    class Batch
      # Lines read
      sig { returns(Integer) }
      def lines; end

      # Stamps new to the watch
      sig { returns(Integer) }
      def stamps; end

      # Exposures sent to the solver
      sig { returns(Integer) }
      def checks; end

      sig { returns(T::Array[Event]) }
      def events; end

      # Counterexamples on checks already failing
      sig { returns(Integer) }
      def known; end

      sig { params(known: Integer).returns(Integer) }
      def known=(known); end

      # Checks with no counterexample within scope
      sig { returns(Integer) }
      def none; end

      sig { params(none: Integer).returns(Integer) }
      def none=(none); end

      sig do
        params(lines: Integer, stamps: Integer, checks: Integer, events: T::Array[Event], known: Integer,
               none: Integer).void
      end
      def initialize(lines:, stamps:, checks:, events:, known:, none:); end

      sig { returns(String) }
      def summary; end

      sig { params(counts: T::Hash[Symbol, Integer]).returns(T::Array[String]) }
      def verdicts(counts); end

      sig { params(number: Integer, noun: String).returns(String) }
      def count(number, noun); end
    end

    class Stamps
      sig { params(set: StampSet, err: T.any(IO, StringIO)).void }
      def initialize(set, err: $stderr)
        @err = T.let(T.unsafe(nil), T.any(IO, StringIO))
        @stamps = T.let(T.unsafe(nil), T::Array[Stamp])
        @unchecked = T.let(T.unsafe(nil), T::Array[Unchecked])
        @routes = T.let(T.unsafe(nil), T::Array[Route])
        @mismatches = T.let(T.unsafe(nil), T::Array[ContextMismatch])
        @revoked_reads = T.let(T.unsafe(nil), T::Array[RevokedRoleRead])
        @unwatched = T.let(T.unsafe(nil), T::Array[RevocationsUnwatched])
        @examples = T.let(T.unsafe(nil), T::Hash[Stamp, Example])
        @seen = T.let(T.unsafe(nil), T::Set[Stamp])
        @baseline = T.let(T.unsafe(nil), T::Set[Stamp])
      end

      sig { returns(StampSet) }
      def set; end

      sig { params(lines: T::Array[String]).returns(T::Array[Stamp]) }
      def fold(lines); end

      sig { params(exposure: AnyExposure).returns(T.nilable(Example)) }
      def example_for(exposure); end

      private

      sig { params(set: StampSet).void }
      def add_examples(set); end

      sig { params(stamp: Stamp, rules: T::Array[String], resource: String).returns(T::Boolean) }
      def live_allow?(stamp, rules, resource); end

      sig { params(lines: T::Array[String]).returns(StampSet) }
      def parse(lines); end
    end

    # Every event reported so far
    sig { returns(T::Array[Event]) }
    attr_reader :events

    sig { returns(Log) }
    attr_reader :log

    sig { returns(Solver) }
    attr_reader :solver

    sig { returns(Source) }
    attr_reader :source

    sig do
      params(mapping: Mapping, baseline: Baseline, source: Source, solver: Solver, mapping_digest: String,
             extractor: T.nilable(Extractor), out: T.any(IO, StringIO), err: T.any(IO, StringIO), json: T::Boolean,
             sarif: T.nilable(String), sarif_fallback: T.nilable(String),
             on_finding: T.nilable(T.proc.params(event: Event).void)).void
    end
    def initialize(mapping:, baseline:, source:, solver:, mapping_digest:, extractor: nil, out: $stdout,
                   err: $stderr, json: false, sarif: nil, sarif_fallback: nil, on_finding: T.unsafe(nil))
      @mapping = T.let(T.unsafe(nil), Mapping)
      @baseline = T.let(T.unsafe(nil), Baseline)
      @source = T.let(T.unsafe(nil), Source)
      @solver = T.let(T.unsafe(nil), Solver)
      @extractor = T.let(T.unsafe(nil), T.nilable(Extractor))
      @out = T.let(T.unsafe(nil), T.any(IO, StringIO))
      @err = T.let(T.unsafe(nil), T.any(IO, StringIO))
      @json = T.let(T.unsafe(nil), T::Boolean)
      @sarif = T.let(T.unsafe(nil), T.nilable(String))
      @sarif_fallback = T.let(T.unsafe(nil), T.nilable(String))
      @on_finding = T.let(T.unsafe(nil), T.nilable(T.proc.params(event: Event).void))
      @events = T.let(T.unsafe(nil), T::Array[Event])
      @log = T.let(T.unsafe(nil), Log)
      @started = T.let(T.unsafe(nil), T::Boolean)
      @stamps = T.let(T.unsafe(nil), Stamps)
      @digests = T.let(T.unsafe(nil), T::Hash[String, String])
      @unknown = T.let(T.unsafe(nil), T::Set[String])
      @failing = T.let(T.unsafe(nil), T::Set[String])
      @known_unchecked = T.let(T.unsafe(nil), T::Set[String])
      @known_drift = T.let(T.unsafe(nil), T::Set[String])
      @known_stale = T.let(T.unsafe(nil), T::Set[String])
    end

    sig { returns(T.nilable(Batch)) }
    def poll; end

    sig { params(once: T::Boolean, interval: Float).returns(Integer) }
    def run(once: false, interval: 2.0); end

    sig { returns(Integer) }
    def exit_code; end

    sig { returns(StampSet) }
    def stamp_set; end

    private

    sig { params(baseline: Baseline, stale: T::Array[String]).void }
    def seed(baseline, stale); end

    sig { params(exposure: AnyExposure, fresh: T::Array[Stamp]).returns(T::Boolean) }
    def changed?(exposure, fresh); end

    sig { params(changed: T::Array[AnyExposure]).returns(T.nilable(Report)) }
    def check(changed); end

    sig { params(batch: Batch, changed: T::Array[AnyExposure], report: T.nilable(Report)).void }
    def verdicts(batch, changed, report); end

    sig { params(batch: Batch, finding: Finding, digests: T::Hash[String, String]).void }
    def found(batch, finding, digests); end

    sig { params(batch: Batch, exposure: AnyExposure, digests: T::Hash[String, String]).void }
    def passed(batch, exposure, digests); end

    sig { params(inference: Inference).returns(T::Array[Event]) }
    def unchecked_events(inference); end

    sig { params(inference: Inference).returns(T::Array[Event]) }
    def drift_events(inference); end

    sig { params(inference: Inference).returns(T::Array[Event]) }
    def stale_events(inference); end

    sig { params(batch: Batch).void }
    def report(batch); end

    sig { params(event: Event).void }
    def emit(event); end

    sig { params(event: Event).void }
    def notify(event); end

    sig { void }
    def write_sarif; end

    sig { void }
    def header; end

    sig { returns(T.nilable(Batch)) }
    def poll_safely; end

    sig { params(interval: Float, block: T.proc.void).void }
    def until_stopped(interval, &block); end
  end
end
