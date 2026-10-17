# typed: strict

module Hallmark
  module Collectors
    module DeclarativePolicyHook
      # Prepended on DeclarativePolicy::Base.
      module Allowed
        sig { params(abilities: T.any(String, Symbol)).returns(T::Boolean) }
        def allowed?(*abilities); end

        # Provided by the policy
        sig { returns(T.untyped) }
        def subject; end
      end

      @installed = T.let(nil, T.nilable(T::Boolean))

      sig { void }
      def self.install; end
    end
  end
end
