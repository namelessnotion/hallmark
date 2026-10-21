# typed: strict

module Hallmark
  class Restriction
    sig { returns(String) }
    def name; end

    sig { returns(T::Array[Denial]) }
    def denials; end

    sig { params(name: String, denials: T::Array[Denial]).void }
    def initialize(name:, denials:); end

    sig { params(name: String, blk: T.proc.bind(Builder).void).returns(Restriction) }
    def self.build(name, &blk); end

    # The denials whose resource, op and fields cover the exposure
    sig { params(exposure: Exposure).returns(T::Array[Denial]) }
    def covering(exposure); end

    sig { params(exposure: Exposure).returns(T::Boolean) }
    def covers?(exposure); end

    sig { returns(T::Array[String]) }
    def roles; end

    # "(not (...))" over the covering denials, for the exposure's check
    sig { params(exposure: Exposure, platform_roles: T::Array[String]).returns(String) }
    def negation(exposure, platform_roles); end

    sig { params(mapping: Mapping).void }
    def validate!(mapping); end

    class Denial
      sig { returns(String) }
      def role; end

      # :read, :write or both
      sig { returns(T::Array[Symbol]) }
      def ops; end

      sig { returns(String) }
      def resource; end

      # The fields it protects; nil for the whole record and every field
      sig { returns(T.nilable(T::Array[String])) }
      def fields; end

      # A guard over the resource's flags limiting the records
      sig { returns(T.nilable(Guard)) }
      def condition; end

      sig do
        params(role: String, ops: T::Array[Symbol], resource: String, fields: T.nilable(T::Array[String]),
               condition: T.nilable(Guard)).void
      end
      def initialize(role:, ops:, resource:, fields: nil, condition: nil); end

      sig { params(exposure: Exposure).returns(T::Boolean) }
      def covers?(exposure); end

      sig { params(platform_roles: T::Array[String]).returns(String) }
      def to_alloy(platform_roles); end

      sig { returns(String) }
      def to_s; end
    end

    class Builder
      include Guard::DSL

      sig { returns(T::Array[Denial]) }
      attr_reader :denials

      sig { params(name: String).void }
      def initialize(name)
        @name = T.let(T.unsafe(nil), String)
        @denials = T.let(T.unsafe(nil), T::Array[Denial])
      end

      # `when:` is checked at run time
      sig do
        params(
          role: T.any(String, Symbol),
          op: T.any(Symbol, T::Array[Symbol]),
          resource: T.any(String, Symbol, T::Module[T.anything]),
          fields: T.nilable(T.any(String, Symbol, T::Array[T.any(String, Symbol)])),
          when: T.nilable(Object)
        ).returns(T::Array[Denial])
      end
      def deny(role:, op:, resource:, fields: nil, when: nil); end

      private

      sig { params(op: T.any(Symbol, T::Array[Symbol])).returns(T::Array[Symbol]) }
      def ops(op); end
    end
  end
end
