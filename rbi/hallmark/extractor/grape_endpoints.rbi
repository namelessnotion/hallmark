# typed: strict

module Hallmark
  class Extractor
    class GrapeEndpoints
      DIRS = T.let(T.unsafe(nil), T::Array[String])
      VERBS = T.let(T.unsafe(nil), T::Array[Symbol])
      SCOPES = T.let(T.unsafe(nil), T::Array[Symbol])
      DEPTH = T.let(T.unsafe(nil), Integer)

      class Endpoint
        sig { returns(String) }
        def name; end

        sig { returns(String) }
        def location; end

        sig { returns(T::Array[Controllers::Authorization]) }
        def authorizations; end

        sig { params(name: String, location: String, authorizations: T::Array[Controllers::Authorization]).void }
        def initialize(name:, location:, authorizations:); end

        sig { returns(T::Boolean) }
        def checked?; end
      end

      # [ability, subject reader, line]
      Check = T.type_alias { [String, T.nilable(String), Integer] }

      sig { returns(T::Array[Endpoint]) }
      attr_reader :endpoints

      sig { params(name: String).returns(T.nilable(String)) }
      def location_of(name); end

      sig { params(mapping: Mapping, root: String).void }
      def initialize(mapping, root)
        @resources = T.let(T.unsafe(nil), T::Array[String])
        @root = T.let(T.unsafe(nil), String)
        @global = T.let(T.unsafe(nil), T::Hash[String, Prism::DefNode])
        @endpoints = T.let(T.unsafe(nil), T::Array[Endpoint])
      end

      private

      sig { params(node: T.nilable(Prism::Node), inside: T::Boolean).void }
      def collect_global_helpers(node, inside); end

      sig { params(node: T.nilable(Prism::Node), file: String).void }
      def read_classes(node, file); end

      sig { params(node: Prism::ClassNode, file: String).void }
      def read_api(node, file); end

      sig { params(node: T.nilable(Prism::Node), helpers: T::Hash[String, Prism::DefNode]).void }
      def collect_helpers(node, helpers); end

      sig do
        params(node: T.nilable(Prism::Node), path: T::Array[String], helpers: T::Hash[String, Prism::DefNode],
               file: String).void
      end
      def read_scope(node, path, helpers, file); end

      sig { params(call: Prism::CallNode).returns(T.nilable(String)) }
      def segment_of(call); end

      sig do
        params(call: Prism::CallNode, path: T::Array[String], helpers: T::Hash[String, Prism::DefNode],
               file: String).void
      end
      def endpoint(call, path, helpers, file); end

      sig do
        params(node: T.nilable(Prism::Node), helpers: T::Hash[String, Prism::DefNode], depth: Integer,
               seen: T::Array[String]).returns(T::Array[Check])
      end
      def checks(node, helpers, depth, seen); end

      sig { params(call: Prism::CallNode).returns(T.nilable(String)) }
      def name_arg(call); end

      sig do
        params(call: Prism::CallNode, helpers: T::Hash[String, Prism::DefNode], depth: Integer,
               seen: T::Array[String]).returns(T::Array[Check])
      end
      def helper_checks(call, helpers, depth, seen); end

      sig { params(call: Prism::CallNode, helpers: T::Hash[String, Prism::DefNode]).returns(T.nilable(Check)) }
      def check_of(call, helpers); end

      sig { params(node: T.nilable(Prism::Node), helpers: T::Hash[String, Prism::DefNode]).returns(T.nilable(String)) }
      def ability_name(node, helpers); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
      def reader_of(node); end

      sig { params(reader: T.nilable(String)).returns(T.nilable(String)) }
      def policy_for(reader); end

      sig { params(node: Prism::Node).returns(T::Array[Prism::CallNode]) }
      def calls(node); end

      sig { params(node: Prism::Node).returns(T::Array[Prism::CallNode]) }
      def calls_with_blocks(node); end

      sig { params(call: Prism::CallNode).returns(T.nilable(Prism::Node)) }
      def block_body(call); end
    end
  end
end
