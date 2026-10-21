# typed: strict

module Hallmark
  module Collectors
    module GraphqlHook
      # Included into graphql-ruby 2.x's trace classes; each passes its
      # arguments and block to `super`.
      module Trace
        sig { params(multiplex: T.untyped).returns(T.untyped) }
        def execute_multiplex(multiplex:); end

        sig { params(query: T.untyped).returns(T.untyped) }
        def execute_query(query:); end

        sig { params(query: T.untyped, multiplex: T.untyped).returns(T.untyped) }
        def execute_query_lazy(query:, multiplex:); end
      end
    end
  end
end
