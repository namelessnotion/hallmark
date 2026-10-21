# typed: strict

module Hallmark
  class Baseline
    FORMAT = T.let(T.unsafe(nil), Integer)

    class Check
      sig { returns(String) }
      def name; end

      sig { returns(String) }
      def action; end

      sig { returns(Symbol) }
      def op; end

      sig { returns(String) }
      def resource; end

      # Exposure#digest
      sig { returns(String) }
      def digest; end

      # "counterexample", "none" or "unknown"
      sig { returns(String) }
      def verdict; end

      sig do
        params(name: String, action: String, op: Symbol, resource: String, digest: String, verdict: String).void
      end
      def initialize(name:, action:, op:, resource:, digest:, verdict:); end

      sig { returns(T::Boolean) }
      def counterexample?; end

      sig { returns(T::Boolean) }
      def unknown?; end

      sig { returns(T::Hash[String, String]) }
      def to_json_object; end
    end

    sig { returns(String) }
    attr_reader :hallmark

    sig { returns(String) }
    attr_reader :alloy

    sig { returns(Integer) }
    attr_reader :scope

    # SHA-256 of the mapping files' bytes
    sig { returns(String) }
    attr_reader :mapping_digest

    # The run its stamps came from; nil when not known
    sig { returns(T.nilable(String)) }
    attr_reader :run

    # The run's stamp, unchecked and route lines, as JSONL
    sig { returns(T::Array[String]) }
    attr_reader :lines

    sig { returns(T::Array[Check]) }
    attr_reader :checks

    # Unchecked entry points that failed
    sig { returns(T::Array[String]) }
    attr_reader :unchecked

    # Drift#key of each drift that failed
    sig { returns(T::Array[String]) }
    attr_reader :drift

    sig { params(reports: T::Array[Report], mapping_digest: String, run: T.nilable(String), scope: Integer).returns(Baseline) }
    def self.build(reports, mapping_digest:, run:, scope: T.unsafe(nil)); end

    sig { params(files: T::Array[String]).returns(String) }
    def self.digest_files(files); end

    sig { params(path: String).returns(Baseline) }
    def self.load(path); end

    sig { params(data: T::Hash[String, T.untyped]).returns(Baseline) }
    def self.from_data(data); end

    sig { params(report: Report).returns(T::Array[Check]) }
    def self.checks_of(report); end

    sig { params(set: T.nilable(StampSet)).returns(T::Array[String]) }
    def self.lines_of(set); end

    sig do
      params(hallmark: String, alloy: String, scope: Integer, mapping_digest: String, run: T.nilable(String),
             lines: T::Array[String], checks: T::Array[Check], unchecked: T::Array[String],
             drift: T::Array[String]).void
    end
    def initialize(hallmark:, alloy:, scope:, mapping_digest:, run:, lines:, checks:, unchecked:, drift:)
      @hallmark = T.let(T.unsafe(nil), String)
      @alloy = T.let(T.unsafe(nil), String)
      @scope = T.let(T.unsafe(nil), Integer)
      @mapping_digest = T.let(T.unsafe(nil), String)
      @run = T.let(T.unsafe(nil), T.nilable(String))
      @lines = T.let(T.unsafe(nil), T::Array[String])
      @checks = T.let(T.unsafe(nil), T::Array[Check])
      @unchecked = T.let(T.unsafe(nil), T::Array[String])
      @drift = T.let(T.unsafe(nil), T::Array[String])
    end

    sig { returns(StampSet) }
    def stamp_set; end

    sig { returns(T::Array[Check]) }
    def failing; end

    sig { params(mapping_digest: String, scope: Integer).returns(T::Array[String]) }
    def stale_reasons(mapping_digest:, scope: T.unsafe(nil)); end

    sig { returns(T::Hash[String, T.untyped]) }
    def to_h; end

    sig { params(args: T.untyped).returns(String) }
    def to_json(*args); end

    sig { params(path: String).returns(Integer) }
    def write(path); end
  end
end
