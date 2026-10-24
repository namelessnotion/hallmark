# typed: strict

module Hallmark
  class Extractor
    class Serializers
      class ActiveModel
        ASSOCIATIONS = T.let(T.unsafe(nil), T::Array[Symbol])

        sig { params(shown: T::Hash[String, Shown], scope: SourceIndex::Scope).void }
        def apply(shown, scope); end

        private

        sig { params(shown: T::Hash[String, Shown], call: SourceIndex::Call).void }
        def attribute(shown, call); end

        sig { params(shown: T::Hash[String, Shown], call: SourceIndex::Call).void }
        def association(shown, call); end

        sig do
          params(shown: T::Hash[String, Shown], call: SourceIndex::Call, name: String,
                 options: T::Hash[String, Prism::Node], association: T.nilable(String)).void
        end
        def add(shown, call, name, options, association: nil); end

        sig { params(options: T::Hash[String, Prism::Node], call: SourceIndex::Call).returns(T::Array[Condition]) }
        def conditions_of(options, call); end

        sig { params(node: Prism::Node).returns(Symbol) }
        def kind_of(node); end
      end
    end
  end
end
