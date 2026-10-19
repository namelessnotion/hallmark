# typed: strict

module Hallmark
  module Collectors
    module PunditHook
      # Prepended on Pundit::Authorization, so these run as methods of its
      # includer: a controller, or any object such as a service object.
      module Authorize
        sig do
          params(record: T.untyped, query: T.nilable(T.any(String, Symbol)), policy_class: T.untyped).returns(T.untyped)
        end
        def authorize(record, query = nil, policy_class: nil); end

        sig { params(args: T.untyped, kwargs: T.untyped).returns(T.untyped) }
        def policy_scope(*args, **kwargs); end

        sig { returns(T.untyped) }
        def skip_authorization; end

        # Provided by a controller; other includers lack it (checked with respond_to?)
        sig { returns(String) }
        def action_name; end

        sig { returns(T.untyped) }
        def pundit_user; end

        # Kernel's, on the includer
        sig { params(name: Symbol, include_all: T::Boolean).returns(T::Boolean) }
        def respond_to?(name, include_all = false); end

        sig { params(record: T.untyped).returns(T.untyped) }
        def policy(record); end

        private

        sig { params(record: T.untyped, policy_class: T.untyped).returns(T.untyped) }
        def hallmark_policy(record, policy_class); end
      end

      OTHER_POLICIES = T.let(T.unsafe(nil), T::Array[String])

      @installed = T.let(nil, T.nilable(T::Boolean))
      @tracer = T.let(nil, T.nilable(TracePoint))
      @wrappers = T.let(nil, T.nilable(T::Hash[T::Class[T.anything], T::Hash[Symbol, UnboundMethod]]))

      class << self
        sig { void }
        def install; end

        sig { params(klass: T.untyped).void }
        def observe_rules(klass); end

        sig { params(klass: T.untyped).returns(T::Boolean) }
        def policy_class?(klass); end

        sig { params(policy: T.untyped, rule: Symbol, block: T.proc.returns(T.untyped)).returns(T.untyped) }
        def query(policy, rule, &block); end

        sig { params(block: T.proc.returns(T.untyped)).returns(T.untyped) }
        def within_rule(&block); end

        sig do
          params(policy: T.untyped, query: String, record: T.untyped, allowed: T::Boolean,
                 raised: T.nilable(String)).void
        end
        def decide(policy, query, record, allowed:, raised: nil); end

        private

        sig { params(klass: T::Class[T.anything], rule: Symbol, original: UnboundMethod).returns(UnboundMethod) }
        def wrap(klass, rule, original); end

        sig { params(klass: T::Class[T.anything], rule: Symbol).returns(T.nilable(UnboundMethod)) }
        def rule_here(klass, rule); end

        sig { params(method: UnboundMethod).returns(T::Boolean) }
        def takes_user_and_record?(method); end

        sig { params(mod: T::Module[T.anything]).returns(T.nilable(String)) }
        def module_name(mod); end
      end
    end
  end
end
