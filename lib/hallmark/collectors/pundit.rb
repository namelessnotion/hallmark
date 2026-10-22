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
    # Policy specs often skip `authorize` and call the rule themselves
    # (`described_class.new(user, record).public_send(:update?)`, as Forem's
    # do, and as the `permit` matcher of pundit/rspec and pundit-matchers'
    # `permit_actions` do). Pundit policies are plain classes with no common
    # base, so each policy class gets its own rules (the public methods ending
    # in `?` that it defines) replaced by wrappers that call the original.
    # Not a prepended module: RSpec's `allow_any_instance_of(SomePolicy)`
    # refuses to stub a method a prepended module defines, which broke
    # Forem's specs. A direct call is stamped as a query:
    # it feeds the rule's guard and ties the rule to no entry point. Calls
    # made inside `authorize`, or from another rule, are not stamped again.
    #
    # Scope classes (`LinkPolicy::Scope`) get their `resolve` wrapped the
    # same way, so `policy_scope`, `Pundit.policy_scope!` and specs calling
    # `Scope.new(user, Link).resolve` all stamp a list decision (rule
    # "Scope#resolve" of the policy the class is nested in; collectors/
    # lists.rb). A `resolve` calling `super` stamps once.
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
            result = PunditHook.within_rule { super }
          rescue ::Pundit::NotAuthorizedError => e
            policy = e.policy unless e.policy.is_a?(Module)
            PunditHook.decide(rule, record, allowed: false) { policy || hallmark_policy(record, policy_class) }
            Kernel.raise
          rescue StandardError => e
            PunditHook.decide(rule, record, allowed: false, raised: e.class.name) do
              hallmark_policy(record, policy_class)
            end
            Kernel.raise
          end
          PunditHook.decide(rule, record, allowed: true) { hallmark_policy(record, policy_class) }
          result
        end

        # A list scope, or an explicit skip, counts as a check; the scope's
        # `resolve` stamps the list.
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

      # Policy classes of the other libraries, which their own hooks observe.
      OTHER_POLICIES = %w[ActionPolicy::Policy::Core DeclarativePolicy::Base].freeze

      class << self
        def install
          return if @installed

          @installed = true
          ::Pundit::Authorization.prepend(Authorize)
          # Policies loaded so far (Rails eager loads them before the Railtie
          # installs the collectors), then each class body Ruby finishes from
          # now on (autoloaded policies, and reopened ones).
          ObjectSpace.each_object(Class) { |klass| observe(klass) }
          @tracer = TracePoint.new(:end) { |trace| observe(trace.self) }
          @tracer.enable
        end

        # A policy's rules, or a scope's `resolve`.
        def observe(klass)
          observe_rules(klass)
          observe_scope(klass)
        end

        # Wraps the rules of a Pundit policy class. Never raises: it runs
        # while the app loads its classes.
        def observe_rules(klass)
          return unless policy_class?(klass)

          wrapped = (@wrappers ||= {}.compare_by_identity)[klass] ||= {}
          # Rules the class defines itself or takes from an included module;
          # rules from a parent class are wrapped on that class. A rule the
          # class body (re)defined since it was wrapped is no longer the
          # wrapper, so it is wrapped again.
          (klass.public_instance_methods - Object.public_instance_methods).each do |rule|
            next unless (current = rule_here(klass, rule))

            wrapped[rule] = wrap(klass, rule, current) unless wrapped[rule] == current
          end
        rescue StandardError => e
          Collectors.warn_once(e)
        end

        # Wraps `resolve` on a Pundit scope class (`<Policy>::Scope`).
        # Never raises.
        def observe_scope(klass)
          return unless scope_class?(klass)

          current = klass.instance_method(:resolve)
          return unless current.owner == klass || !current.owner.is_a?(Class)

          wrapped = (@scopes ||= {}.compare_by_identity)
          wrapped[klass] = wrap_scope(klass, current) unless wrapped[klass] == current
        rescue StandardError => e
          Collectors.warn_once(e)
        end

        # A class named `<Something>Policy::Scope` that Pundit could build
        # with `new(user, scope)` and that answers `resolve`.
        def scope_class?(klass)
          return false unless klass.is_a?(Class) && !klass.singleton_class? && klass < Object
          return false unless ListScope.pundit_policy(module_name(klass))&.end_with?("Policy")
          return false unless klass.public_method_defined?(:resolve)

          takes_user_and_record?(klass.instance_method(:initialize))
        end

        # Runs one `resolve`, and stamps its list unless it runs inside
        # another (`super`).
        def resolve(scope)
          return yield if !Collectors.active? || Thread.current[:hallmark_pundit_scope]

          begin
            Thread.current[:hallmark_pundit_scope] = true
            result = yield
          ensure
            Thread.current[:hallmark_pundit_scope] = nil
          end
          listed(scope, result)
          result
        end

        # Stamps a resolved list. Never raises.
        def listed(scope, result)
          policy = ListScope.pundit_policy(module_name(scope.class)).to_s
          context = Collectors.recording? ? Collectors.facts&.context_of(policy, scope) : nil
          return Collectors.checked! unless context

          Collectors.list(policy: context, rule: ListScope::PUNDIT_RULE, result: result,
                          model: scope.instance_variable_get(:@scope))
        rescue StandardError => e
          Collectors.warn_once(e)
        end

        # A class named like a Pundit policy (`LinkPolicy`) that Pundit could
        # build with `new(user, record)`, and no other library's policy.
        # The arity check leaves out Rails' own `*Policy` classes.
        def policy_class?(klass)
          return false unless klass.is_a?(Class) && !klass.singleton_class? && klass < Object
          return false unless module_name(klass)&.end_with?("Policy")
          return false if klass.ancestors.any? { |ancestor| OTHER_POLICIES.include?(module_name(ancestor)) }

          takes_user_and_record?(klass.instance_method(:initialize))
        end

        # Runs one rule called on a policy, and stamps it unless it runs
        # inside `authorize` or another rule. The record is the policy's
        # `@record`, where Pundit's generated policies keep it.
        # The block is named: Ruby 3.3.0 rejects an anonymous block parameter
        # used inside another block (a SyntaxError; Forem runs 3.3.0).
        def query(policy, rule, &rule_body)
          return yield if !Collectors.active? || Thread.current[:hallmark_pundit_rule]

          record = policy.instance_variable_get(:@record)
          within_rule { Collectors.observe(policy: policy, rule: rule, record: record, enforced: false, &rule_body) }
        end

        # Marks the thread as inside a rule while the block runs, so the
        # rules it calls are not stamped.
        def within_rule
          outer = Thread.current[:hallmark_pundit_rule]
          Thread.current[:hallmark_pundit_rule] = true
          yield
        ensure
          Thread.current[:hallmark_pundit_rule] = outer
        end

        # Stamps one `authorize` call under the current request's entry point,
        # if any, with the policy the block gives (built only when the
        # decision is sampled). Never raises: the caller is about to return
        # the app's result or re-raise the app's exception.
        def decide(query, record, allowed:, raised: nil)
          Collectors.checked!
          return unless Collectors.recording? && (policy = yield)

          model = record.is_a?(Array) ? record.last : record
          Collectors.decision(policy: policy, rule: query, record: model, allowed: allowed, raised: raised,
                              enforced: true)
        rescue StandardError => e
          Collectors.warn_once(e)
        end

        private

        # Replaces one rule on a policy class with a wrapper that calls the
        # original (so its `super` still reaches the parent class), passing
        # the arguments, the block and the result through untouched. Returns
        # the wrapper. Warnings are off while it is defined: replacing a
        # method warns "method redefined" under `ruby -w`.
        def wrap(klass, rule, original)
          verbose = $VERBOSE
          $VERBOSE = nil
          klass.define_method(rule) do |*args, **kwargs, &block|
            PunditHook.query(self, rule) { original.bind(self).call(*args, **kwargs, &block) }
          end
          klass.instance_method(rule)
        ensure
          $VERBOSE = verbose
        end

        # Replaces `resolve` on a scope class, as `wrap` does a rule.
        def wrap_scope(klass, original)
          verbose = $VERBOSE
          $VERBOSE = nil
          klass.define_method(:resolve) do |*args, **kwargs, &block|
            PunditHook.resolve(self) { original.bind(self).call(*args, **kwargs, &block) }
          end
          klass.instance_method(:resolve)
        ensure
          $VERBOSE = verbose
        end

        # The rule's current method when it is to be wrapped on this class:
        # a `?` method the class defines or takes from a module.
        def rule_here(klass, rule)
          return unless rule.end_with?("?")

          method = klass.instance_method(rule)
          method if method.owner == klass || !method.owner.is_a?(Class)
        end

        def takes_user_and_record?(method)
          kinds = method.parameters.map(&:first)
          required = kinds.count(:req)
          required <= 2 && !kinds.include?(:keyreq) && (kinds.include?(:rest) || required + kinds.count(:opt) >= 2)
        end

        # A class's own name, even when it overrides `name`.
        def module_name(mod) = Module.instance_method(:name).bind_call(mod)
      end
    end
  end
end
