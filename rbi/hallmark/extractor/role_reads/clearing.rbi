# typed: strict

module Hallmark
  class Extractor
    class RoleReads
      CALLBACKS = T.let(T.unsafe(nil), T::Array[Symbol])
      HOOKED = T.let(T.unsafe(nil), T::Array[Symbol])
      CLEARS = T.let(T.unsafe(nil), T::Array[Symbol])
      RESETS = T.let(T.unsafe(nil), T::Array[Symbol])

      class Deletion
        # :key, :glob, :regexp or :reset
        sig { returns(Symbol) }
        def kind; end

        sig { returns(String) }
        def text; end

        sig { returns(T.nilable(String)) }
        def owner; end

        sig { returns(String) }
        def via; end

        sig { returns(String) }
        def location; end

        sig { params(kind: Symbol, text: String, owner: T.nilable(String), via: String, location: String).void }
        def initialize(kind:, text:, owner:, via:, location:); end

        sig { returns(String) }
        def to_s; end
      end

      private

      sig { void }
      def judge; end

      sig { returns(T::Array[String]) }
      def clearing_classes; end

      sig { params(klass: String).returns(T::Array[Deletion]) }
      def callbacks_of(klass); end

      sig { params(klass: String, call: SourceIndex::Call).returns(T::Array[Deletion]) }
      def callback_deletions(klass, call); end

      sig { params(node: T.untyped).returns(T::Array[String]) }
      def symbols(node); end

      sig do
        params(klass: String, name: String, via: String, depth: Integer, seen: T::Set[[String, String]])
          .returns(T::Array[Deletion])
      end
      def clear_walk(klass, name, via, depth, seen); end

      sig do
        params(node: T.nilable(Prism::Node), frame: Frame, via: String, seen: T::Set[[String, String]])
          .returns(T::Array[Deletion])
      end
      def deletions_in(node, frame, via, seen); end

      sig do
        params(call: Prism::CallNode, frame: Frame, via: String, seen: T::Set[[String, String]])
          .returns(T::Array[Deletion])
      end
      def followed(call, frame, via, seen); end

      sig { params(node: Prism::Node, frame: Frame, via: String, locals: Locals).returns(T::Array[Deletion]) }
      def deletion(node, frame, via, locals); end

      sig do
        params(call: Prism::CallNode, frame: Frame, via: String, locals: Locals, location: String)
          .returns(T::Array[Deletion])
      end
      def call_deletions(call, frame, via, locals, location); end

      sig { params(call: Prism::CallNode, frame: Frame, via: String, locals: Locals).returns(T::Array[Deletion]) }
      def cache_deletions(call, frame, via, locals); end

      sig { params(call: Prism::CallNode, first: T.nilable(Prism::Node)).returns(T::Array[T.nilable(Prism::Node)]) }
      def deleted_keys(call, first); end

      sig do
        params(node: T.nilable(Prism::Node), frame: Frame, locals: Locals, via: String, location: String)
          .returns(T.nilable(Deletion))
      end
      def matched(node, frame, locals, via, location); end

      sig { params(call: Prism::CallNode).returns(T.nilable(String)) }
      def reset_target(call); end

      sig do
        params(name: String, value: Prism::Node, frame: Frame, via: String, location: String)
          .returns(T::Array[Deletion])
      end
      def reset_of(name, value, frame, via, location); end

      sig { params(cache: Cache, deletions: T::Array[Deletion]).returns(T.nilable(String)) }
      def clearing(cache, deletions); end

      sig { params(cache: Cache).returns(T::Boolean) }
      def memo?(cache); end

      sig { params(deletion: Deletion, cache: Cache).returns(T::Boolean) }
      def reset?(deletion, cache); end

      sig { params(deletion: Deletion, key: T.nilable(String)).returns(T::Boolean) }
      def matches?(deletion, key); end

      sig { params(membership: String, call: SourceIndex::Call, versions: T::Array[String]).returns(T::Boolean) }
      def touching?(membership, call, versions); end

      sig { params(cache: Cache).returns(T.nilable(String)) }
      def touched_by(cache); end
    end
  end
end
