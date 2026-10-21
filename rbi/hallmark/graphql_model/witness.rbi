# typed: strict

module Hallmark
  class GraphqlModel
    class Witness
      # A breadth-first state: the atom, its type, the steps so far
      State = T.type_alias { [String, String, T::Array[Step]] }

      FactsFor = T.type_alias { T.proc.params(atom: String).returns(Facts) }

      sig { params(model: GraphqlModel, instance: Receipt::Instance).void }
      def initialize(model, instance)
        @model = T.let(T.unsafe(nil), GraphqlModel)
        @instance = T.let(T.unsafe(nil), Receipt::Instance)
      end

      sig { params(check: GraphqlCheck).returns(T.nilable(String)) }
      def path(check); end

      private

      sig do
        params(check: GraphqlCheck, atoms: T::Hash[String, T.nilable(String)], strict: T::Boolean)
          .returns(T.nilable(T::Array[Step]))
      end
      def search(check, atoms, strict:); end

      sig do
        params(queue: T::Array[State], goal: [String, String], facts: T.nilable(FactsFor))
          .returns(T.nilable(T::Array[Step]))
      end
      def breadth_first(queue, goal, facts); end

      sig { params(atoms: T::Hash[String, T.nilable(String)]).returns(FactsFor) }
      def facts_for(atoms); end

      sig { params(start: String, facts: T.nilable(FactsFor)).returns(T::Array[Edge]) }
      def entries(start, facts); end

      sig { params(guard: Guard, atom: String, facts: T.nilable(FactsFor)).returns(T::Boolean) }
      def passes?(guard, atom, facts); end

      sig do
        params(atom: String, type: String, steps: T::Array[Step], facts: T.nilable(FactsFor)).returns(T::Array[State])
      end
      def next_states(atom, type, steps, facts); end

      sig { params(type: String, atom: String).returns(T::Boolean) }
      def fits?(type, atom); end

      sig { params(steps: T::Array[Step], leaf: String).returns(String) }
      def render(steps, leaf); end
    end

    class Facts
      sig do
        params(instance: Receipt::Instance, principal: String, current: T.nilable(String), atom: String).void
      end
      def initialize(instance, principal, current, atom)
        @instance = T.let(T.unsafe(nil), Receipt::Instance)
        @principal = T.let(T.unsafe(nil), String)
        @current = T.let(T.unsafe(nil), T.nilable(String))
        @atom = T.let(T.unsafe(nil), String)
      end

      sig { params(leaf: Guard).returns(T.nilable(T::Boolean)) }
      def [](leaf); end

      private

      sig { returns(T.nilable(String)) }
      def tenant; end

      sig { returns(T::Array[String]) }
      def assigned; end

      sig { params(name: String, where: T.nilable(Symbol)).returns(T::Boolean) }
      def role?(name, where); end

      sig { params(where: Symbol).returns(T.nilable(String)) }
      def scope(where); end
    end
  end
end
