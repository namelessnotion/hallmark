# typed: strict
# frozen_string_literal: true

module Hallmark
  module Collectors
    # Action Policy: every rule application goes through `apply_r`, which
    # sees the policy instance (its record and authorization context). The
    # `action_policy.authorize` notification, which Action Policy fires
    # around `authorize!` when its Rails instrumentation is on (the
    # default), says whether an application is an enforcing `authorize!` or
    # a query such as `allowed_to?`.
    module ActionPolicyHook
      AUTHORIZE_EVENT = "action_policy.authorize"

      # Prepended on ActionPolicy::Base, above its per-policy rule cache, so a
      # cached `authorize!` after an `allowed_to?` is still seen.
      module BaseApply
        def apply_r(rule) = ActionPolicyHook.observe(self, rule) { super }
      end

      # Prepended on ActionPolicy::Policy::Core, for policies that include
      # only the core (the first phase of a Pundit migration).
      module CoreApply
        def apply_r(rule) = ActionPolicyHook.observe(self, rule) { super }
      end

      # `authorized_scope` authorizes a list; it counts as a check.
      module Scoped
        def authorized_scope(*, **)
          Collectors.checked!
          super
        end
      end

      # An explicit opt-out of `verify_authorized` is not an unchecked entry point.
      module Skip
        def skip_verify_authorized!(*)
          Collectors.checked!
          super
        end
      end

      # Tracks the `authorize!` calls in progress on this thread.
      class Listener
        def start(_name, _event_id, payload)
          ActionPolicyHook.authorizing.push([payload[:policy].to_s, Collectors.rule_name(payload[:rule])])
        end

        def finish(_name, _event_id, _payload)
          ActionPolicyHook.authorizing.pop
          Collectors.checked!
        end
      end

      class << self
        def install
          return if @installed

          @installed = true
          ::ActionPolicy::Base.prepend(BaseApply)
          ::ActionPolicy::Policy::Core.prepend(CoreApply)
          ::ActionPolicy::Behaviours::Scoping.prepend(Scoped)
          ::ActionPolicy::Controller.prepend(Skip) if defined?(::ActionPolicy::Controller)
          return unless defined?(::ActiveSupport::Notifications)

          ::ActiveSupport::Notifications.subscribe(AUTHORIZE_EVENT, Listener.new)
        end

        def authorizing = Thread.current[:hallmark_action_policy_authorizing] ||= []

        # Stamps one application. A policy seen by both hooks (a Base
        # policy) is observed once, by the outer one.
        def observe(policy, rule, &)
          applying = Thread.current[:hallmark_action_policy_applying] ||= []
          return yield if !Collectors.active? || applying.last.equal?(policy)

          applying.push(policy)
          begin
            current = authorizing.last
            enforced = !current.nil? && current[1] == Collectors.rule_name(rule) && current[0] == policy.class.name.to_s
            Collectors.observe(policy: policy, rule: rule, record: policy.record, enforced: enforced,
                               outcome: :value, &)
          ensure
            applying.pop
          end
        end
      end
    end
  end
end
