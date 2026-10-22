# typed: strict

module Hallmark
  module Collectors
    module ListProbe
      ORIGIN = T.let(T.unsafe(nil), Symbol)

      class Origin
        sig { returns(T.untyped) }
        def policy; end

        sig { returns(String) }
        def rule; end

        sig { returns(T.nilable(Request)) }
        def request; end

        sig { params(policy: T.untyped, rule: String, request: T.nilable(Request)).void }
        def initialize(policy, rule, request); end
      end

      # Extended onto a lazy result, which provides `loaded?`
      module Loading
        sig { returns(T::Boolean) }
        def loaded?; end

        sig { params(args: T.untyped, kwargs: T.untyped, blk: T.untyped).returns(T.untyped) }
        def load(*args, **kwargs, &blk); end
      end

      class << self
        sig { params(result: T.untyped, origin: Origin).void }
        def attach(result, origin); end

        sig { params(result: T.untyped).void }
        def loaded(result); end

        sig { params(result: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
        def loaded_records(result); end

        sig { params(value: T.untyped).returns(T.nilable(T::Module[T.anything])) }
        def model_of(value); end
      end
    end
  end
end
