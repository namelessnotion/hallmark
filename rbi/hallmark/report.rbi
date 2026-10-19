# typed: strict

module Hallmark
  class Report
    sig { returns(Analysis) }
    attr_reader :analysis

    sig { returns(T::Array[Finding]) }
    attr_reader :findings

    # Exposures with no counterexample within scope
    sig { returns(T::Array[Exposure]) }
    attr_reader :verified

    COMBINATIONS_SHOWN = T.let(T.unsafe(nil), Integer)
    ROUTES_SHOWN = T.let(T.unsafe(nil), Integer)

    class Unknown
      sig { returns(Exposure) }
      def exposure; end

      sig { returns(String) }
      def reason; end

      sig { params(exposure: Exposure, reason: String).void }
      def initialize(exposure, reason); end
    end

    # Exposures the solver gave no verdict for
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

    sig { params(analysis: Analysis, receipt: Receipt).void }
    def initialize(analysis, receipt)
      @analysis = T.let(T.unsafe(nil), Analysis)
      @findings = T.let(T.unsafe(nil), T::Array[Finding])
      @verified = T.let(T.unsafe(nil), T::Array[Exposure])
      @unknown = T.let(T.unsafe(nil), T::Array[Unknown])
      @unchecked = T.let(T.unsafe(nil), T::Array[String])
      @drift = T.let(T.unsafe(nil), T::Array[Drift])
      @coverage = T.let(T.unsafe(nil), T.nilable(Coverage))
    end

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

    sig { params(exposure: Exposure, reason: String).returns(String) }
    def self.unknown_line(exposure, reason); end

    sig { params(exposure: Exposure).returns(String) }
    def self.ok_line(exposure); end

    sig { params(finding: Finding).returns(T::Array[String]) }
    def finding_lines(finding); end

    sig { returns(String) }
    def summary; end

    sig { params(total: Integer).returns(T::Array[String]) }
    def problems(total); end

    sig { returns(T::Array[String]) }
    def drift_lines; end

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
    def opaque_lines(coverage); end

    sig { params(coverage: Coverage).returns(T::Hash[String, T::Array[String]]) }
    def coverage_lists(coverage); end

    sig { params(coverage: Coverage).returns(T::Hash[String, T::Array[String]]) }
    def route_lists(coverage); end

    sig { params(coverage: Coverage).returns(T::Array[String]) }
    def route_lines(coverage); end

    private

    sig { params(exposure: Exposure, receipt: Receipt).void }
    def read(exposure, receipt); end
  end
end
