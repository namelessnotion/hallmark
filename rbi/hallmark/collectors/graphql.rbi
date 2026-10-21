# typed: strict

module Hallmark
  module Collectors
    module GraphqlHook

      class Frame
        # :field, :authorized, :lazy or :query
        sig { returns(Symbol) }
        def kind; end

        sig { returns(Scope) }
        def scope; end

        # The response path 1.x passes its tracers
        sig { returns(T.nilable(T::Array[T.any(String, Integer)])) }
        def path; end

        sig { params(kind: Symbol, scope: Scope, path: T.nilable(T::Array[T.any(String, Integer)])).void }
        def initialize(kind, scope, path); end
      end

      class Scope
        # A GraphQL::Query
        sig { returns(T.untyped) }
        attr_reader :query

        sig { returns(Frame) }
        attr_reader :field

        sig { returns(Frame) }
        attr_reader :authorized

        sig { returns(Frame) }
        attr_reader :lazy

        sig { returns(Frame) }
        attr_reader :outside

        sig { params(query: T.untyped).void }
        def initialize(query)
          @query = T.let(T.unsafe(nil), T.untyped)
          @field = T.let(T.unsafe(nil), Frame)
          @authorized = T.let(T.unsafe(nil), Frame)
          @lazy = T.let(T.unsafe(nil), Frame)
          @outside = T.let(T.unsafe(nil), Frame)
          @names = T.let(T.unsafe(nil), T::Hash[T::Array[String], String])
          @operation = T.let(T.unsafe(nil), T.nilable(String))
        end

        sig { returns(String) }
        def operation; end

        sig { params(frame: Frame).returns(String) }
        def name(frame); end

        sig { params(keys: T::Array[String]).returns(String) }
        def path_name(keys); end

        private

        sig { returns(T::Array[T.untyped]) }
        def root_selections; end

        sig do
          params(selections: T::Array[T.untyped], key: String, found: T::Array[T.untyped]).returns(T::Array[T.untyped])
        end
        def fields_named(selections, key, found); end
      end

      class TypeCheck
        sig { returns(T.untyped) }
        def type; end

        sig { returns(T.untyped) }
        def object; end

        # The query's GraphQL::Query::Context
        sig { returns(T.untyped) }
        def context; end

        sig { returns(T.nilable(Frame)) }
        def previous; end

        sig { returns(T.nilable(T::Boolean)) }
        def decided; end

        sig do
          params(type: T.untyped, object: T.untyped, context: T.untyped, previous: T.nilable(Frame),
                 decided: T.nilable(T::Boolean)).void
        end
        def initialize(type, object, context, previous, decided); end
      end

      class Registry
        # The field frame of a multiplex of one query
        sig { returns(T.nilable(Frame)) }
        attr_reader :field

        # `multiplex` is a GraphQL::Execution::Multiplex
        sig { params(multiplex: T.untyped).void }
        def initialize(multiplex)
          @multiplex = T.let(T.unsafe(nil), T.untyped)
          @scopes = T.let(T.unsafe(nil), T::Hash[T.untyped, Scope])
          @last = T.let(T.unsafe(nil), T.nilable(Scope))
          @field = T.let(T.unsafe(nil), T.nilable(Frame))
        end

        sig { params(query: T.untyped).returns(Scope) }
        def scope(query); end

        sig { params(query: T.untyped, rest: T.untyped, blk: T.untyped).returns(Frame) }
        def field_frame(query:, **rest, &blk); end

        sig { params(query: T.untyped, rest: T.untyped, blk: T.untyped).returns(Frame) }
        def lazy_frame(query:, **rest, &blk); end

        sig do
          params(query: T.untyped, type: T.untyped, object: T.untyped, blk: T.untyped).returns(T.nilable(TypeCheck))
        end
        def type_check(query:, type:, object:, &blk); end

        sig { returns(String) }
        def name; end

        sig { returns(T.proc.returns(String)) }
        def entry_point; end
      end

      module LegacyTracer
        sig do
          params(key: String, data: T::Hash[Symbol, T.untyped], blk: T.proc.returns(T.untyped)).returns(T.untyped)
        end
        def self.trace(key, data, &blk); end

        sig do
          params(registry: Registry, key: String, data: T::Hash[Symbol, T.untyped],
                 blk: T.proc.returns(T.untyped)).returns(T.untyped)
        end
        def self.event(registry, key, data, &blk); end

        sig do
          params(registry: Registry, data: T::Hash[Symbol, T.untyped], blk: T.proc.returns(T.untyped))
            .returns(T.untyped)
        end
        def self.authorized(registry, data, &blk); end
      end

      module TenantCheck
        sig { params(scope: Scope).void }
        def self.compare(scope); end

        # The controller, its current tenant reader and the context's reader
        sig { params(host: T.untyped).returns(T.nilable([T.untyped, String, Proc])) }
        def self.readers(host); end

        sig { params(tenant: T.untyped).returns(T.nilable(String)) }
        def self.class_name(tenant); end

        sig { params(host: T.untyped).returns(String) }
        def self.entry_point(host); end
      end

      @installed = T.let(nil, T.nilable(T::Boolean))
      @custom = T.let(nil, T.nilable(T::Hash[T.untyped, T::Boolean]))
      @tracer = T.let(nil, T.nilable(TracePoint))

      class << self
        sig { void }
        def install; end

        sig { params(klass: T.untyped).void }
        def attach(klass); end

        sig do
          type_parameters(:R)
            .params(multiplex: T.untyped, blk: T.proc.returns(T.type_parameter(:R))).returns(T.type_parameter(:R))
        end
        def within_multiplex(multiplex, &blk); end

        sig do
          type_parameters(:R).params(frame: Frame, blk: T.proc.returns(T.type_parameter(:R))).returns(T.type_parameter(:R))
        end
        def within(frame, &blk); end

        sig do
          params(frame: Frame, type: T.untyped, object: T.untyped, context: T.untyped,
                 blk: T.proc.returns(T.untyped)).returns(T.untyped)
        end
        def authorized(frame, type, object, context, &blk); end

        sig { params(frame: Frame, type: T.untyped, object: T.untyped, context: T.untyped).returns(TypeCheck) }
        def start(frame, type, object, context); end

        sig { params(check: TypeCheck, result: T.untyped).returns(T.untyped) }
        def finish(check, result); end

        sig { params(check: TypeCheck, error: StandardError).void }
        def failed(check, error); end

        sig { params(check: TypeCheck).void }
        def restore(check); end

        sig { params(type: T.untyped).returns(T::Boolean) }
        def custom?(type); end

        private

        sig { params(check: TypeCheck, allowed: T.untyped, raised: T.nilable(String)).void }
        def stamp_type(check, allowed, raised); end

        sig { params(type: T.untyped, context: T.untyped).returns(ContextPolicy) }
        def context_policy(type, context); end
      end
    end
  end
end
