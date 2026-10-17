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

      # Prepended on Pundit::RSpec::Matchers.
      module Permit
        sig { params(user: T.untyped, record: T.untyped).returns(T.untyped) }
        def permit(user, record); end
      end

      # Prepended on the singleton class of one `permit` matcher.
      module PermitMatcher
        sig { params(policy: T.untyped).returns(T::Boolean) }
        def matches?(policy); end

        sig { params(policy: T.untyped).returns(T::Boolean) }
        def does_not_match?(policy); end
      end

      class ObservedPolicy
        sig { params(policy_class: T.untyped).void }
        def initialize(policy_class)
          @policy_class = T.let(policy_class, T.untyped)
        end

        sig { params(user: T.untyped, record: T.untyped).returns(ObservedRule) }
        def new(user, record); end

        sig { returns(String) }
        def to_s; end

        sig { returns(String) }
        def inspect; end
      end

      class ObservedRule
        sig { params(policy: T.untyped, record: T.untyped).void }
        def initialize(policy, record)
          @policy = T.let(policy, T.untyped)
          @record = T.let(record, T.untyped)
        end

        sig { params(rule: T.any(String, Symbol), args: T.untyped).returns(T.untyped) }
        def public_send(rule, *args); end
      end

      @installed = T.let(nil, T.nilable(T::Boolean))
      @rspec_installed = T.let(nil, T.nilable(T::Boolean))
      @rspec_waiting = T.let(nil, T.nilable(T::Boolean))

      class << self
        sig { void }
        def install; end

        sig { void }
        def install_rspec; end

        sig do
          params(policy: T.untyped, query: String, record: T.untyped, allowed: T::Boolean,
                 raised: T.nilable(String)).void
        end
        def decide(policy, query, record, allowed:, raised: nil); end
      end
    end
  end
end
