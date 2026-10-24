# typed: strict

module Hallmark
  class Extractor
    class RoleReads
      class Cache
        sig { returns(String) }
        def shape; end

        sig { returns(T.nilable(String)) }
        def key; end

        sig { returns(T.nilable(String)) }
        def expires_in; end

        # The method holding the read, as "Class#name", or the start's label
        sig { returns(String) }
        def holder; end

        sig { returns(String) }
        def location; end

        sig { returns(String) }
        def start; end

        sig { returns(T::Array[String]) }
        def path; end

        sig { returns(T.nilable(String)) }
        def owner; end

        sig { returns(T::Array[String]) }
        def versions; end

        sig { returns(T.nilable(String)) }
        def cleared; end

        sig { params(cleared: T.nilable(String)).returns(T.nilable(String)) }
        def cleared=(cleared); end

        sig { returns(T.nilable(String)) }
        def accepted; end

        sig { params(accepted: T.nilable(String)).returns(T.nilable(String)) }
        def accepted=(accepted); end

        sig { returns(T::Array[String]) }
        def searched; end

        sig { params(searched: T::Array[String]).returns(T::Array[String]) }
        def searched=(searched); end

        sig do
          params(shape: String, key: T.nilable(String), expires_in: T.nilable(String), holder: String,
                 location: String, start: String, path: T::Array[String], owner: T.nilable(String),
                 versions: T::Array[String], cleared: T.nilable(String), accepted: T.nilable(String),
                 searched: T::Array[String]).void
        end
        def initialize(shape:, key:, expires_in:, holder:, location:, start:, path:, owner:, versions:, cleared:,
                       accepted:, searched:); end

        sig { returns(T::Boolean) }
        def clearable?; end

        sig { returns(String) }
        def walked; end

        sig { returns(String) }
        def described; end

        sig { returns(String) }
        def message; end

        sig { returns(String) }
        def to_s; end
      end

      module Caches
        NOT_CACHES = T.let(T.unsafe(nil), T::Array[String])
        FRAMEWORK = T.let(T.unsafe(nil), T::Array[String])
        CLAIMS = T.let(T.unsafe(nil), T::Array[String])
        READS = T.let(T.unsafe(nil), T::Array[Symbol])
        STORES = T.let(T.unsafe(nil), T::Array[Symbol])
        JARS = T.let(T.unsafe(nil), T::Array[Symbol])
        VERSIONS = T.let(T.unsafe(nil), T::Array[String])

        sig { params(args: T::Array[Prism::Node]).returns(T::Hash[String, Prism::Node]) }
        def self.options(args); end

        sig { params(name: String).returns(String) }
        def self.camelize(name); end

        sig { params(class_name: String).returns(String) }
        def self.file_name(class_name); end

        sig { params(node: T.untyped).returns(T::Boolean) }
        def self.rails?(node); end

        sig { params(node: T.untyped).returns(T::Boolean) }
        def self.rails_cache_call?(node); end

        sig { params(node: T.untyped).returns(T::Boolean) }
        def self.jwt_decode?(node); end

        sig { params(node: T.untyped).returns(T::Boolean) }
        def self.empty_value?(node); end
      end

      private

      sig { params(node: Prism::Node, frame: Frame, method: T.nilable(SourceIndex::Method), locals: Locals).void }
      def detect_caches(node, frame, method, locals); end

      sig do
        params(node: Prism::Node, frame: Frame, holder: String, shape: String, key: T.nilable(String),
               expires_in: T.nilable(String), versions: T::Array[String]).returns(Cache)
      end
      def add_cache(node, frame, holder, shape:, key:, expires_in: nil, versions: []); end

      sig { params(calls: T::Array[Prism::CallNode], frame: Frame, holder: String, locals: Locals).void }
      def token_caches(calls, frame, holder, locals); end

      sig { params(call: Prism::CallNode, frame: Frame, holder: String, locals: Locals).returns(T.nilable(Cache)) }
      def rails_cache(call, frame, holder, locals); end

      sig { params(node: T.untyped, frame: Frame, locals: Locals).returns(T::Boolean) }
      def rails_cache?(node, frame, locals); end

      sig { params(call: Prism::CallNode, frame: Frame, holder: String, locals: Locals).returns(T.nilable(Cache)) }
      def store_cache(call, frame, holder, locals); end

      sig { params(node: T.untyped).returns(T.nilable(String)) }
      def store_shape(node); end

      sig { params(node: T.untyped, name: Symbol).returns(T::Boolean) }
      def named?(node, name); end

      sig { params(call: Prism::CallNode, locals: Locals).returns(T::Boolean) }
      def claim_read?(call, locals); end

      sig { params(node: T.untyped, locals: Locals).returns(T::Boolean) }
      def claims?(node, locals); end

      sig { params(node: Prism::Node, frame: Frame, holder: String, method: SourceIndex::Method).void }
      def memo_cache(node, frame, holder, method); end

      sig { params(node: Prism::Node).returns(T.nilable(String)) }
      def memo_variable(node); end

      sig { params(node: Prism::Node, method: SourceIndex::Method).returns(T::Boolean) }
      def reads_input?(node, method); end

      sig { params(node: T.untyped).returns(T::Array[String]) }
      def all_parameters(node); end

      sig do
        params(node: T.nilable(Prism::Node), frame: Frame, locals: Locals, versions: T::Array[String])
          .returns(T.nilable(String))
      end
      def key_of(node, frame, locals, versions = []); end

      sig do
        params(node: T.any(Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode), frame: Frame,
               versions: T::Array[String]).returns(String)
      end
      def interpolated(node, frame, versions); end

      sig { params(node: Prism::Node, frame: Frame, versions: T::Array[String]).void }
      def versioned(node, frame, versions); end

      sig { params(node: Prism::CallNode, frame: Frame, versions: T::Array[String]).returns(String) }
      def call_key(node, frame, versions); end
    end
  end
end
