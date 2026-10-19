# typed: strict

module Hallmark
  module Collectors
    module GrapeHook
      # Prepended on Grape::Endpoint.
      module Run
        sig { returns(T.untyped) }
        def run; end

        # Provided by the endpoint
        sig { returns(T.untyped) }
        def env; end
      end

      @installed = T.let(nil, T.nilable(T::Boolean))

      sig { void }
      def self.install; end

      sig { params(env: T.untyped).returns(T.nilable(String)) }
      def self.entry_point(env); end

      sig { params(origin: String, prefix: T.untyped, version: T.untyped).returns(String) }
      def self.path(origin, prefix, version); end
    end
  end
end
