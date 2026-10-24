# typed: strict

module Hallmark
  class Extractor
    class GrapeEndpoints
      class Presents
        SKIPPED = T.let(T.unsafe(nil), T::Array[String])

        class Presented
          sig { returns(Prism::Node) }
          def expression; end

          sig { returns(T::Hash[String, Prism::Node]) }
          def options; end

          sig { returns(Locals) }
          def locals; end

          sig { returns(String) }
          def location; end

          sig do
            params(expression: Prism::Node, options: T::Hash[String, Prism::Node], locals: Locals,
                   location: String).void
          end
          def initialize(expression:, options:, locals:, location:); end
        end

        # [entity as written, the branches it adds, why it is unknown]
        Entity = T.type_alias { [T.nilable(String), T::Array[Serializers::Branch], T.nilable(String)] }

        sig do
          params(endpoints: GrapeEndpoints, helpers: T::Hash[String, Prism::DefNode], api: Api,
                 authorizations: T::Array[Controllers::Authorization]).void
        end
        def initialize(endpoints, helpers, api, authorizations)
          @endpoints = T.let(T.unsafe(nil), GrapeEndpoints)
          @helpers = T.let(T.unsafe(nil), T::Hash[String, Prism::DefNode])
          @api = T.let(T.unsafe(nil), Api)
          @authorizations = T.let(T.unsafe(nil), T::Array[Controllers::Authorization])
          @found = T.let(T.unsafe(nil), T::Array[Serializers::Rendering])
        end

        sig { params(node: T.nilable(Prism::Node)).returns(T::Array[Serializers::Rendering]) }
        def read(node); end

        private

        sig do
          params(node: T.nilable(Prism::Node), file: String, branches: T::Array[Serializers::Branch], locals: Locals,
                 depth: Integer).void
        end
        def walk(node, file, branches, locals, depth); end

        sig do
          params(node: T.any(Prism::IfNode, Prism::UnlessNode), file: String, branches: T::Array[Serializers::Branch],
                 locals: Locals, depth: Integer).void
        end
        def branch(node, file, branches, locals, depth); end

        sig { params(node: Prism::Node, negated: T::Boolean, file: String, locals: Locals).returns(Serializers::Branch) }
        def condition(node, negated, file, locals); end

        sig do
          params(node: Prism::CallNode, file: String, branches: T::Array[Serializers::Branch], locals: Locals,
                 depth: Integer).void
        end
        def call(node, file, branches, locals, depth); end

        sig { params(node: Prism::CallNode, depth: Integer).returns(T.nilable(Prism::DefNode)) }
        def forwarding_helper(node, depth); end

        sig { params(helper: Prism::DefNode).returns(T::Boolean) }
        def presents?(helper); end

        sig { params(node: T.nilable(Prism::Node)).returns(T::Boolean) }
        def contains_present?(node); end

        sig { params(helper: Prism::DefNode, call: Prism::CallNode, locals: Locals).returns(Locals) }
        def bind(helper, call, locals); end

        sig do
          params(bound: Locals, params: Prism::ParametersNode, keywords: T.nilable(Prism::KeywordHashNode),
                 locals: Locals).returns(Locals)
        end
        def bind_keywords(bound, params, keywords, locals); end

        sig { params(params: Prism::ParametersNode).returns(T::Array[String]) }
        def parameter_names(params); end

        sig do
          params(node: Prism::CallNode, file: String, branches: T::Array[Serializers::Branch], locals: Locals).void
        end
        def present(node, file, branches, locals); end

        sig { params(node: T.nilable(Prism::Node), locals: Locals).returns(T::Hash[String, Prism::Node]) }
        def hash_of(node, locals); end

        sig { params(node: T.nilable(Prism::Node), file: String, locals: Locals).returns(T::Array[Entity]) }
        def entities(node, file, locals); end

        sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
        def unknown(node); end

        sig do
          params(presented: Presented, branches: T::Array[Serializers::Branch], entity: T.nilable(String),
                 unknown: T.nilable(String)).returns(Serializers::Rendering)
        end
        def rendering(presented, branches, entity, unknown); end

        sig { params(node: Prism::Node).returns(T::Boolean) }
        def list?(node); end

        sig { params(node: T.nilable(Prism::Node)).returns(T::Boolean) }
        def chain_list?(node); end
      end
    end
  end
end
