# typed: strict
# frozen_string_literal: true

module Hallmark
  module Collectors
    # Pundit has no instrumentation, so this prepends `authorize` on
    # Pundit::Authorization, the module controllers (and any other object,
    # such as a service object) include. Every `authorize` call enforces: a
    # deny raises Pundit::NotAuthorizedError. Outside a request the stamp has
    # no entry point, as with Action Policy and DeclarativePolicy, so the rule
    # feeds its guard but ties to no entry point.
    #
    # A policy spec's `permit` matcher (pundit/rspec) builds the policy and
    # calls each rule itself; prepending `permit` stamps those calls as
    # queries, which feed rule guards but tie no rule to an entry point.
    module PunditHook
      # Prepended on Pundit::Authorization.
      module Authorize
        def authorize(record, query = nil, policy_class: nil)
          return super unless Collectors.active?

          # A local, not the parameter: the bare `super` passes the
          # parameters as they are now, and Pundit (and apps rescuing its
          # error) see the query exactly as the caller gave it.
          rule = query || ("#{action_name}?" if respond_to?(:action_name, true))
          # No query and no action (a plain object): Pundit fails on its own,
          # exactly as it would without the hook.
          return super unless rule

          rule = rule.to_s
          begin
            result = super
          rescue ::Pundit::NotAuthorizedError => e
            policy = e.policy unless e.policy.is_a?(Module)
            PunditHook.decide(policy || hallmark_policy(record, policy_class), rule, record, allowed: false)
            Kernel.raise
          rescue StandardError => e
            policy = hallmark_policy(record, policy_class)
            PunditHook.decide(policy, rule, record, allowed: false, raised: e.class.name)
            Kernel.raise
          end
          PunditHook.decide(hallmark_policy(record, policy_class), rule, record, allowed: true)
          result
        end

        # A list scope, or an explicit skip, counts as a check.
        def policy_scope(*, **)
          Collectors.checked!
          super
        end

        def skip_authorization
          Collectors.checked!
          super
        end

        private

        # The policy `authorize` used; Pundit memoizes it per record. Nil when
        # it cannot be built (a constructor that rejects anonymous users).
        def hallmark_policy(record, policy_class)
          return policy(record) unless policy_class

          policy_class.new(pundit_user, record.is_a?(Array) ? record.last : record)
        rescue StandardError
          nil
        end
      end

      # Prepended on Pundit::RSpec::Matchers: the matcher it returns is
      # handed a stand-in for the policy class.
      module Permit
        def permit(user, record)
          matcher = super
          matcher.singleton_class.prepend(PermitMatcher)
          matcher
        end
      end

      # Prepended on one `permit` matcher, so it checks the stand-in.
      module PermitMatcher
        def matches?(policy) = super(ObservedPolicy.new(policy))
        def does_not_match?(policy) = super(ObservedPolicy.new(policy))
      end

      # Stands in for the policy class a `permit` matcher is given: builds the
      # real policy, and stamps each rule the matcher calls on it.
      class ObservedPolicy
        def initialize(policy_class)
          @policy_class = policy_class
        end

        def new(user, record) = ObservedRule.new(@policy_class.new(user, record), record)
        def to_s = @policy_class.to_s
        def inspect = @policy_class.inspect
      end

      # The matcher calls `public_send(rule)` on what `new` returned.
      class ObservedRule
        def initialize(policy, record)
          @policy = policy
          @record = record
        end

        def public_send(rule, *args)
          Collectors.observe(policy: @policy, rule: rule, record: @record, enforced: false) do
            @policy.public_send(rule, *args)
          end
        end
      end

      class << self
        def install
          return if @installed

          @installed = true
          ::Pundit::Authorization.prepend(Authorize)
          install_rspec
        end

        # pundit/rspec usually loads after the app, and so after the Railtie
        # installs the collectors; then the hook waits for the suite to start.
        def install_rspec
          if defined?(::Pundit::RSpec::Matchers)
            return if @rspec_installed

            @rspec_installed = true
            ::Pundit::RSpec::Matchers.prepend(Permit)
          elsif !@rspec_waiting && defined?(::RSpec) && ::RSpec.respond_to?(:configure)
            @rspec_waiting = true
            ::RSpec.configure { |config| config.before(:suite) { PunditHook.install_rspec } }
          end
        end

        # Stamps one `authorize` call under the current request's entry point,
        # if any. Never raises: the caller is about to return the app's result
        # or re-raise the app's exception.
        def decide(policy, query, record, allowed:, raised: nil)
          Collectors.checked!
          return unless policy

          model = record.is_a?(Array) ? record.last : record
          Collectors.decision(policy: policy, rule: query, record: model, allowed: allowed, raised: raised,
                              enforced: true)
        rescue StandardError => e
          Collectors.warn_once(e)
        end
      end
    end
  end
end
