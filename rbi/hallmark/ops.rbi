# typed: strict

module Hallmark
  class Ops
    READ_NAMES = T.let(T.unsafe(nil), T::Array[String])
    READ_PREFIXES = T.let(T.unsafe(nil), T::Array[String])
    READ_SUFFIXES = T.let(T.unsafe(nil), T::Array[String])
    SAFE_VERBS = T.let(T.unsafe(nil), T::Array[String])

    sig { params(mapping: Mapping, policy: String, name: String).returns(T.nilable(Symbol)) }
    def self.named(mapping, policy, name); end

    sig { params(name: String).returns(T::Boolean) }
    def self.read_name?(name); end

    sig do
      params(mapping: Mapping, stamps: T::Array[Stamp], routes: T::Array[Route],
             controllers: T.nilable(Extractor::Controllers)).void
    end
    def initialize(mapping, stamps: [], routes: [], controllers: nil)
      @mapping = T.let(T.unsafe(nil), Mapping)
      @stamps = T.let(T.unsafe(nil), T::Array[Stamp])
      @controllers = T.let(T.unsafe(nil), T.nilable(Extractor::Controllers))
      # Entry point => the verbs of its routes ("" for any)
      @verbs = T.let(T.unsafe(nil), T::Hash[String, T::Array[String]])
      @reaching = T.let(T.unsafe(nil), T.nilable(T::Hash[String, T::Array[String]]))
      @unresolved = T.let(T.unsafe(nil), T.nilable(T::Hash[String, T::Array[String]]))
    end

    sig { params(policy: String, name: String).returns(T.nilable(Symbol)) }
    def fetch(policy, name); end

    sig { params(policy: String, name: String).returns(T.nilable(String)) }
    def basis(policy, name); end

    private

    sig { params(policy: String, name: String).returns(T.nilable(T::Array[String])) }
    def gets_only(policy, name); end

    sig { params(entry_point: String).returns(T::Boolean) }
    def safe?(entry_point); end

    sig { params(entry_point: String).returns(T::Array[String]) }
    def grape_verb(entry_point); end

    sig { returns([T::Hash[String, T::Array[String]], T::Hash[String, T::Array[String]]]) }
    def links; end

    sig do
      params(entry_point: String, reaching: T::Hash[String, T::Array[String]],
             unresolved: T::Hash[String, T::Array[String]]).void
    end
    def link_code(entry_point, reaching, unresolved); end
  end
end
