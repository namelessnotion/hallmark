# typed: strict

module Hallmark
  class Report
    sig { returns(Analysis) }
    attr_reader :analysis

    sig { returns(T::Array[Finding]) }
    attr_reader :findings

    # AnyExposures with no counterexample within scope
    sig { returns(T::Array[AnyExposure]) }
    attr_reader :verified

    COMBINATIONS_SHOWN = T.let(T.unsafe(nil), Integer)
    ROUTES_SHOWN = T.let(T.unsafe(nil), Integer)

    class Unknown
      sig { returns(AnyExposure) }
      def exposure; end

      sig { returns(String) }
      def reason; end

      sig { params(exposure: AnyExposure, reason: String).void }
      def initialize(exposure, reason); end
    end

    # AnyExposures the solver gave no verdict for
    sig { returns(T::Array[Unknown]) }
    attr_reader :unknown

    sig { params(reports: T::Array[Report]).returns(Integer) }
    def self.exit_code(reports); end

    # Entry points that finished without an authorization call (threat 10)
    sig { returns(T::Array[String]) }
    attr_reader :unchecked

    # Stamped decisions the extracted guards contradict
    sig { returns(T::Array[Drift]) }
    attr_reader :drift

    sig { returns(T.nilable(Coverage)) }
    attr_reader :coverage

    sig { returns(T::Array[Extractor::DeclarativeTranslator::Lint]) }
    attr_reader :lints

    sig { params(analysis: Analysis, receipt: Receipt).void }
    def initialize(analysis, receipt)
      @analysis = T.let(T.unsafe(nil), Analysis)
      @findings = T.let(T.unsafe(nil), T::Array[Finding])
      @verified = T.let(T.unsafe(nil), T::Array[AnyExposure])
      @unknown = T.let(T.unsafe(nil), T::Array[Unknown])
      @unchecked = T.let(T.unsafe(nil), T::Array[String])
      @drift = T.let(T.unsafe(nil), T::Array[Drift])
      @coverage = T.let(T.unsafe(nil), T.nilable(Coverage))
      @lints = T.let(T.unsafe(nil), T::Array[Extractor::DeclarativeTranslator::Lint])
    end

    # The extractor behind the analysis's guards, if any
    sig { returns(T.nilable(Extractor)) }
    def extractor; end

    sig { returns(T::Boolean) }
    def failed?; end

    sig { returns(T::Boolean) }
    def clean?; end

    sig { returns(Integer) }
    def exit_code; end

    sig { returns(String) }
    def to_s; end

    sig { params(finding: Finding).returns(T::Array[String]) }
    def self.finding_lines(finding); end

    sig { params(exposure: AnyExposure, reason: String).returns(String) }
    def self.unknown_line(exposure, reason); end

    sig { params(exposure: AnyExposure).returns(String) }
    def self.ok_line(exposure); end

    # What a failing exposure does, with the serializer field that shows it
    sig { params(exposure: AnyExposure).returns(String) }
    def self.doing(exposure); end

    sig { params(lint: Extractor::DeclarativeTranslator::Lint).returns(String) }
    def self.hazard(lint); end

    sig { params(analysis: Analysis).returns(T::Array[Extractor::DeclarativeTranslator::Lint]) }
    def self.lints_of(analysis); end

    # A G5 lint with the list checks of its type's scope_items named
    sig do
      params(lint: Extractor::DeclarativeTranslator::Lint, analysis: Analysis)
        .returns(Extractor::DeclarativeTranslator::Lint)
    end
    def self.linked(lint, analysis); end

    sig { params(finding: Finding).returns(T::Array[String]) }
    def finding_lines(finding); end

    sig { returns(String) }
    def summary; end

    sig { params(total: Integer).returns(T::Array[String]) }
    def problems(total); end

    sig { params(total: Integer).returns(T.nilable(String)) }
    def verdicts(total); end

    sig { returns(T::Array[String]) }
    def drift_lines; end

    sig { returns(T::Array[String]) }
    def field_lines; end

    sig { returns(T::Array[String]) }
    def trailer_lines; end

    sig { returns(T::Array[String]) }
    def graphql_lines; end

    sig { returns(T::Array[String]) }
    def serializer_lines; end

    sig { params(title: String, items: T::Array[String]).returns(T::Array[String]) }
    def note_lines(title, items); end

    sig { params(item: Drift).returns(T::Array[String]) }
    def self.drift_lines(item); end

    sig { returns(T::Array[String]) }
    def unknown_lines; end

    sig { params(total: Integer).returns(String) }
    def unknown_summary(total); end

    sig { params(number: Integer, noun: String).returns(String) }
    def count(number, noun); end

    sig { returns(T::Array[String]) }
    def coverage_lines; end

    sig { params(coverage: Coverage).returns(T::Array[String]) }
    def coverage_notes(coverage); end

    sig { params(coverage: Coverage).returns(T::Array[String]) }
    def opaque_lines(coverage); end

    sig { params(coverage: Coverage).returns(T::Array[String]) }
    def mismatch_lines(coverage); end

    sig { params(coverage: Coverage).returns(T::Hash[String, T::Array[String]]) }
    def coverage_lists(coverage); end

    sig { params(coverage: Coverage).returns(T::Hash[String, T::Array[String]]) }
    def route_lists(coverage); end

    sig { params(coverage: Coverage).returns(T::Array[String]) }
    def route_lines(coverage); end

    private

    sig { params(exposure: AnyExposure, receipt: Receipt).void }
    def read(exposure, receipt); end
  end
end
