# typed: strict

module Hallmark
  class UncheckedRequests
    REDIRECTS = T.let(T.unsafe(nil), T::Array[Integer])
    SAFE_VERBS = T.let(T.unsafe(nil), T::Array[String])

    sig { params(mapping: Mapping, stamps: T::Array[Stamp], extractor: T.nilable(Extractor), coverage: Coverage).void }
    def initialize(mapping, stamps, extractor, coverage)
      @mapping = T.let(T.unsafe(nil), Mapping)
      @stamps = T.let(T.unsafe(nil), T::Array[Stamp])
      @extractor = T.let(T.unsafe(nil), T.nilable(Extractor))
      @coverage = T.let(T.unsafe(nil), Coverage)
    end

    sig { params(events: T::Array[Unchecked]).returns(T::Array[String]) }
    def failing(events); end

    private

    sig { params(entry_point: String).returns(T::Boolean) }
    def verify_skipped?(entry_point); end

    sig { params(event: Unchecked).returns(T::Boolean) }
    def redirect_before_check?(event); end
  end
end
