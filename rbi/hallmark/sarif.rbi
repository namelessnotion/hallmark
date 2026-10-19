# typed: strict

module Hallmark
  class Sarif
    SCHEMA = T.let(T.unsafe(nil), String)
    INFORMATION_URI = T.let(T.unsafe(nil), String)

    class Rule
      sig { returns(String) }
      def id; end

      sig { returns(String) }
      def short; end

      sig { returns(String) }
      def help; end

      sig { params(id: String, short: String, help: String).void }
      def initialize(id:, short:, help:); end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h; end
    end

    sig { returns(T::Array[Rule]) }
    def self.rules; end

    sig { params(reports: T::Array[Report], fallback: T.nilable(String)).void }
    def initialize(reports, fallback: nil)
      @reports = T.let(T.unsafe(nil), T::Array[Report])
      @fallback = T.let(T.unsafe(nil), T.nilable(String))
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def to_h; end

    sig { params(args: T.untyped).returns(String) }
    def to_json(*args); end

    private

    sig { params(report: Report).returns(T::Array[T::Hash[String, T.untyped]]) }
    def results(report); end

    sig { params(finding: Finding).returns(T::Hash[String, T.untyped]) }
    def finding_result(finding); end

    sig { params(report: Report, entry_point: String).returns(T::Hash[String, T.untyped]) }
    def unchecked_result(report, entry_point); end

    sig { params(item: Drift).returns(T::Hash[String, T.untyped]) }
    def drift_result(item); end

    sig do
      params(rule: String, text: String, locations: T::Array[String], identity: String)
        .returns(T::Hash[String, T.untyped])
    end
    def result(rule, text, locations, identity); end

    sig { params(location: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def physical(location); end

    sig { params(uri: String, line: T.nilable(Integer)).returns(T::Hash[String, T.untyped]) }
    def artifact(uri, line); end
  end
end
