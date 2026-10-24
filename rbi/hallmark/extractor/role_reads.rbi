# typed: strict

module Hallmark
  class Extractor
    class RoleReads
      # A local's class name, or the node assigned to it (for keys)
      Locals = T.type_alias { T::Hash[String, T.any(String, Prism::Node)] }

      class Start
        sig { returns(String) }
        def label; end

        # Methods walked, as "Class#name" or "Class.name"
        sig { returns(T::Array[String]) }
        def walked; end

        sig { params(label: String, walked: T::Array[String]).void }
        def initialize(label:, walked:); end

        sig { returns(String) }
        def to_s; end
      end

      class Frame
        sig { returns(T.nilable(String)) }
        def klass; end

        sig { returns(T::Boolean) }
        def singleton; end

        sig { returns(T::Hash[String, String]) }
        def env; end

        sig { params(env: T::Hash[String, String]).returns(T::Hash[String, String]) }
        def env=(env); end

        sig { returns(String) }
        def file; end

        sig { returns(T::Array[String]) }
        def path; end

        sig { params(path: T::Array[String]).returns(T::Array[String]) }
        def path=(path); end

        sig { returns(Integer) }
        def depth; end

        sig { returns(Start) }
        def start; end

        sig do
          params(klass: T.nilable(String), singleton: T::Boolean, env: T::Hash[String, String], file: String,
                 path: T::Array[String], depth: Integer, start: Start).void
        end
        def initialize(klass:, singleton:, env:, file:, path:, depth:, start:); end
      end

      class Unread
        sig { returns(String) }
        def call; end

        sig { returns(String) }
        def location; end

        sig { returns(String) }
        def start; end

        sig { params(call: String, location: String, start: String).void }
        def initialize(call:, location:, start:); end

        sig { returns(String) }
        def to_s; end
      end

      class Accepted
        sig { returns(String) }
        def holder; end

        sig { returns(String) }
        def location; end

        sig { returns(String) }
        def reason; end

        sig { params(holder: String, location: String, reason: String).void }
        def initialize(holder:, location:, reason:); end

        sig { returns(String) }
        def to_s; end
      end

      sig { returns(T::Array[Start]) }
      attr_reader :starts

      sig { returns(T::Array[Cache]) }
      attr_reader :caches

      sig { returns(T::Array[Unread]) }
      attr_reader :unread

      sig { returns(T::Array[Accepted]) }
      attr_reader :accepted

      sig { params(mapping: Mapping, root: String, policies: SourceIndex, rules: T::Array[Extracted]).void }
      def initialize(mapping, root, policies:, rules:)
        @mapping = T.let(T.unsafe(nil), Mapping)
        @root = T.let(T.unsafe(nil), String)
        @policies = T.let(T.unsafe(nil), SourceIndex)
        @models = T.let(T.unsafe(nil), SourceIndex)
        @loaded = T.let(T.unsafe(nil), T::Set[String])
        @associations = T.let(T.unsafe(nil), T::Hash[String, T::Hash[String, T.nilable(String)]])
        @visited = T.let(T.unsafe(nil), T::Hash[String, Integer])
        @starts = T.let(T.unsafe(nil), T::Array[Start])
        @caches = T.let(T.unsafe(nil), T::Array[Cache])
        @unread = T.let(T.unsafe(nil), T::Array[Unread])
        @accepted = T.let(T.unsafe(nil), T::Array[Accepted])
        @quiet = T.let(T.unsafe(nil), T::Boolean)
      end

      sig { returns(T::Array[DeclarativeTranslator::Lint]) }
      def lints; end

      sig { params(name: T.nilable(String)).returns(T.nilable(SourceIndex)) }
      def index_for(name); end

      sig { params(klass: T.nilable(String), name: String).returns(T.nilable(SourceIndex::Method)) }
      def find_method(klass, name); end

      ASSOCIATIONS = T.let(T.unsafe(nil), T::Array[Symbol])

      sig { params(klass: String, name: String).returns(T.nilable(String)) }
      def association(klass, name); end

      sig { params(klass: String, name: String).returns(T::Boolean) }
      def data?(klass, name); end

      private

      sig { returns(String) }
      def principal; end

      sig { returns(T.nilable(String)) }
      def tenant_class; end

      sig { params(klass: T.nilable(String), env: T::Hash[String, String], start: Start, file: String).returns(Frame) }
      def frame(klass, env, start, file); end

      sig do
        params(klass: T.nilable(String), name: String, caller: Frame, site: String,
               bind: T::Array[T.nilable(String)], method: T.nilable(SourceIndex::Method)).void
      end
      def visit(klass, name, caller, site:, bind: [], method: nil); end

      sig { params(node: Prism::Node, frame: Frame).returns(String) }
      def site_of(node, frame); end

      sig { params(call: String, site: String, frame: Frame).returns(NilClass) }
      def not_followed(call, site, frame); end

      sig do
        params(klass: T.nilable(String), method: SourceIndex::Method, caller: Frame, bind: T::Array[T.nilable(String)])
          .returns(T::Hash[String, String])
      end
      def callee_env(klass, method, caller, bind); end

      sig { params(klass: T.nilable(String), name: String).returns(String) }
      def method_label(klass, name); end

      sig { params(node: T.nilable(Prism::Node), block: T.proc.params(node: Prism::Node).void).void }
      def each_node(node, &block); end

      sig { params(node: T.nilable(Prism::Node), frame: Frame, method: T.nilable(SourceIndex::Method)).void }
      def scan(node, frame, method: nil); end

      sig { params(node: Prism::Node, frame: Frame).returns(Locals) }
      def locals_of(node, frame); end

      sig { params(call: Prism::CallNode, frame: Frame).void }
      def follow(call, frame); end

      sig { params(call: Prism::CallNode, frame: Frame).returns(T.nilable([String, String])) }
      def callee(call, frame); end

      sig { params(call: Prism::CallNode, frame: Frame, name: String).returns(T.nilable([String, String])) }
      def own_callee(call, frame, name); end

      sig do
        params(receiver: T.any(Prism::ConstantReadNode, Prism::ConstantPathNode), frame: Frame, name: String)
          .returns(T.nilable([String, String]))
      end
      def constant_callee(receiver, frame, name); end

      sig { params(name: String, frame: Frame).returns(T.nilable(String)) }
      def resolve_constant(name, frame); end

      sig { params(name: String, klass: T.nilable(String)).returns(T.nilable(String)) }
      def resolve_in(name, klass); end

      sig do
        params(klass: T.nilable(String), name: String, caller: Frame, site: String,
               bind: T::Array[T.nilable(String)]).void
      end
      def unfound(klass, name, caller, site, bind); end

      sig { params(call: Prism::CallNode, frame: Frame).returns(T::Array[T.nilable(String)]) }
      def call_classes(call, frame); end

      sig { params(node: T.nilable(Prism::Node), frame: Frame).returns(T.nilable(String)) }
      def class_of(node, frame); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(T.nilable(String)) }
      def call_class(node, frame); end

      sig { params(klass: String, name: String).returns(T::Boolean) }
      def attribute?(klass, name); end

      sig { params(klass: String).returns(T::Hash[String, T.nilable(String)]) }
      def associations(klass); end

      sig { params(klass: String).returns(T::Hash[String, T.nilable(String)]) }
      def read_associations(klass); end

      sig { params(call: SourceIndex::Call, name: String).returns(T.nilable(String)) }
      def association_class(call, name); end

      sig { params(name: String).void }
      def load_class(name); end

      sig { params(ref: String, namespace: T::Array[String]).returns(T::Array[String]) }
      def candidates(ref, namespace); end

      sig { params(file: String).returns(String) }
      def relative(file); end

      sig { void }
      def validate_accepted!; end
    end
  end
end
