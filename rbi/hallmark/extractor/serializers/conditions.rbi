# typed: strict

module Hallmark
  class Extractor
    class Serializers
      class Conditions
        OPTION = T.let(T.unsafe(nil), Regexp)
        PARAMS = T.let(T.unsafe(nil), Regexp)

        # Renders a node as the translator does
        Render = T.type_alias { T.proc.params(node: Prism::Node).returns(String) }

        sig do
          params(mapping: Mapping, index: SourceIndex, translator: MethodTranslator, terms: Terms,
                 policies: Extractor).void
        end
        def initialize(mapping, index, translator, terms:, policies:)
          @mapping = T.let(T.unsafe(nil), Mapping)
          @index = T.let(T.unsafe(nil), SourceIndex)
          @translator = T.let(T.unsafe(nil), MethodTranslator)
          @terms = T.let(T.unsafe(nil), Terms)
          @policies = T.let(T.unsafe(nil), Extractor)
          @user = T.let(T.unsafe(nil), String)
        end

        sig { params(condition: Condition, context: Context).returns(Guard) }
        def guard(condition, context); end

        private

        sig { params(condition: Condition, context: Context).returns(Guard) }
        def lambda_guard(condition, context); end

        sig { params(condition: Condition, context: Context).returns(Guard) }
        def method_guard(condition, context); end

        sig { params(condition: Condition, context: Context).returns(Guard) }
        def written(condition, context); end

        sig { params(node: Prism::Node, context: Context).returns(Guard) }
        def hash_guard(node, context); end

        sig { params(context: Context).returns(T::Hash[String, String]) }
        def base_aliases(context); end

        sig { params(serializer: String).returns(T::Array[String]) }
        def record_readers(serializer); end

        sig { params(method: SourceIndex::Method).returns(T::Boolean) }
        def reads_object?(method); end

        sig { params(aliases: T::Hash[String, String]).returns(T::Hash[String, String]) }
        def default_aliases(aliases); end

        sig { params(context: Context).returns(MethodTranslator::Resolver) }
        def resolver(context); end

        sig { params(node: Prism::CallNode, render: Render, context: Context).returns(T.nilable(Guard)) }
        def comparison(node, render, context); end

        sig { params(node: Prism::CallNode, render: Render, args: T::Array[Prism::Node]).returns(T.nilable(String)) }
        def compared_option(node, render, args); end

        sig { params(key: String, context: Context).returns(Guard) }
        def option_value(key, context); end

        sig { params(key: String, value: Prism::Node, context: Context).returns(Guard) }
        def option_equals(key, value, context); end

        sig { params(node: Prism::Node, rendering: Rendering).returns(Guard) }
        def option_opaque(node, rendering); end

        sig { params(node: Prism::Node).returns(T.nilable(Guard)) }
        def literal_value(node); end

        sig { params(node: Prism::Node, rendering: Rendering).returns(T::Boolean) }
        def user?(node, rendering); end

        sig { params(node: Prism::Node, rendering: Rendering).returns(T::Boolean) }
        def params?(node, rendering); end

        sig { params(node: Prism::Node, rendering: Rendering).returns(String) }
        def render(node, rendering); end

        sig { params(node: Prism::Node, context: Context).returns(T.nilable(Guard)) }
        def option_authorization(node, context); end

        sig { params(node: Prism::CallNode, rendering: Rendering).returns(T::Boolean) }
        def on_rendered?(node, rendering); end

        sig { params(node: Prism::CallNode).returns(T.nilable(String)) }
        def ability_call(node); end

        sig { params(node: Prism::CallNode).returns(T::Boolean) }
        def ability_named?(node); end

        sig { params(node: Prism::CallNode, render: Render, context: Context).returns(T.nilable(Guard)) }
        def authorization(node, render, context); end

        sig do
          params(node: Prism::CallNode, render: Render, context: Context, resource: String).returns(T.nilable(Guard))
        end
        def ability_guard(node, render, context, resource); end

        sig { params(text: String, rendering: T.nilable(Rendering)).returns(T::Boolean) }
        def unpassed?(text, rendering); end

        sig { params(node: Prism::CallNode, render: Render).returns(T.nilable(String)) }
        def rule_call(node, render); end

        sig { params(node: Prism::CallNode, render: Render).returns(T.nilable(String)) }
        def allowed_to_rule(node, render); end

        sig { params(node: Prism::CallNode, receiver: Prism::CallNode, render: Render).returns(T.nilable(String)) }
        def policy_rule(node, receiver, render); end

        sig { params(node: Prism::Node, file: String).returns(Guard) }
        def opaque(node, file); end
      end
    end
  end
end
