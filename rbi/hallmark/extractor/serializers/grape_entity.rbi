# typed: strict

module Hallmark
  class Extractor
    class Serializers
      class GrapeEntity
        class Place
          sig { returns(String) }
          def file; end

          sig { returns(SourceIndex::Scope) }
          def scope; end

          sig { returns(T::Array[Condition]) }
          def conditions; end

          sig { returns(T.nilable(String)) }
          def prefix; end

          sig do
            params(file: String, scope: SourceIndex::Scope, conditions: T::Array[Condition],
                   prefix: T.nilable(String)).void
          end
          def initialize(file:, scope:, conditions:, prefix:); end

          sig { params(conditions: T::Array[Condition], prefix: T.nilable(String)).returns(Place) }
          def within(conditions: self.conditions, prefix: self.prefix); end
        end

        sig { params(shown: T::Hash[String, Shown], scope: SourceIndex::Scope).void }
        def apply(shown, scope); end

        private

        sig { params(shown: T::Hash[String, Shown], node: Prism::Node, place: Place).void }
        def statement(shown, node, place); end

        sig { params(shown: T::Hash[String, Shown], call: Prism::CallNode, place: Place).void }
        def expose(shown, call, place); end

        sig { params(shown: T::Hash[String, Shown], call: Prism::CallNode, place: Place, name: String, path: String).void }
        def add(shown, call, place, name, path); end

        sig { params(place: Place, key: T.nilable(Prism::Node), name: String).returns(String) }
        def path(place, key, name); end

        sig { params(shown: T::Hash[String, Shown], block: Prism::BlockNode, place: Place).void }
        def nest(shown, block, place); end

        sig { params(shown: T::Hash[String, Shown], call: Prism::CallNode, place: Place).void }
        def with_options(shown, call, place); end

        sig { params(options: T::Hash[String, Prism::Node], place: Place).returns(T::Array[Condition]) }
        def conditions_of(options, place); end

        sig { params(node: Prism::Node).returns(Symbol) }
        def kind_of(node); end
      end
    end
  end
end
