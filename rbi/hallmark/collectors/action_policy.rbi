# typed: strict

module Hallmark
  module Collectors
    module ActionPolicyHook
      AUTHORIZE_EVENT = T.let(T.unsafe(nil), String)

      module BaseApply
        sig { params(rule: T.any(String, Symbol)).returns(T.untyped) }
        def apply_r(rule); end
      end

      module CoreApply
        sig { params(rule: T.any(String, Symbol)).returns(T.untyped) }
        def apply_r(rule); end
      end

      module Scoped
        sig { params(args: T.untyped, kwargs: T.untyped).returns(T.untyped) }
        def authorized_scope(*args, **kwargs); end
      end

      module Skip
        sig { params(args: T.untyped).returns(T.untyped) }
        def skip_verify_authorized!(*args); end
      end

      class Listener
        sig { params(_name: String, _event_id: String, payload: T::Hash[Symbol, T.untyped]).void }
        def start(_name, _event_id, payload); end

        sig { params(_name: String, _event_id: String, _payload: T::Hash[Symbol, T.untyped]).void }
        def finish(_name, _event_id, _payload); end
      end

      @installed = T.let(nil, T.nilable(T::Boolean))

      class << self
        sig { void }
        def install; end

        # [policy class name, rule] for each `authorize!` in progress
        sig { returns(T::Array[[String, String]]) }
        def authorizing; end

        sig { params(policy: T.untyped, rule: T.any(String, Symbol), blk: T.proc.returns(T.untyped)).returns(T.untyped) }
        def observe(policy, rule, &blk); end
      end
    end
  end
end
