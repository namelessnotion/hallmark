# typed: strict
# frozen_string_literal: true

module Hallmark
  # Runtime collectors: hooks into each authorization library that turn
  # every decision into an event on the request thread and hand it to a
  # StampStore, which writes stamps off the request thread. Nothing here
  # runs the solver.
  #
  # Each library's hook is loaded only when the library is present:
  #
  #   Action Policy      prepends `apply_r` on policies; subscribes to
  #                      `action_policy.authorize` to tell `authorize!` from
  #                      `allowed_to?`
  #   Pundit             prepends `authorize` and `policy_scope` on
  #                      Pundit::Authorization
  #   DeclarativePolicy  prepends `allowed?` on DeclarativePolicy::Base
  #   Action Controller  an `around_action` that flags entry points finishing
  #                      without an authorization call (threat 10)
  #
  # The Railtie installs them in the test environment. A hook never breaks
  # the app: a fact that cannot be read drops the stamp with a warning.
  module Collectors
    # The entry point a request is running, and whether it called any rule.
    Request = Struct.new(:entry_point, :checked, :halted, keyword_init: true)

    class << self
      attr_reader :store, :facts

      def install!(mapping: Hallmark.configuration.mapping, store: StampStore.new(Hallmark.configuration.stamps))
        unless mapping
          raise ConfigurationError,
                "the collectors need a mapping; declare one with `Hallmark.configure { |c| c.map { ... } }`"
        end

        @facts = Facts.new(mapping.validate_collection!)
        @store = store
        @warned = {}
        install_libraries
        @active = true
        self
      end

      # Stops recording. The prepended hooks stay in place but do nothing.
      def uninstall!
        @store&.flush
        @active = false
      end

      def active? = @active == true

      # Whether to collect: the configured mode when set, else only in the
      # test environment.
      def enabled?(mode, environment) = mode ? mode == "test" : environment == "test"

      def flush = @store&.flush

      # Runs a block as one entry point, such as "LinksController#update".
      def within_entry_point(name)
        previous = Thread.current[:hallmark_request]
        request = Request.new(entry_point: name, checked: false, halted: false)
        Thread.current[:hallmark_request] = request
        yield request
      ensure
        Thread.current[:hallmark_request] = previous
      end

      def current_request = Thread.current[:hallmark_request]

      # Marks the current request as authorized without a decision to stamp:
      # a list scope, or an explicit skip such as Pundit's `skip_authorization`.
      def checked!
        request = current_request
        request.checked = true if request
      end

      # Records an entry point that finished without an authorization call,
      # with the response status and the HTTP verb when a controller knows them.
      def unchecked!(entry_point, status: nil, verb: nil)
        return unless active?

        @store&.record(Unchecked.new(entry_point: entry_point, status: status, verb: verb))
      end

      # Runs one rule and stamps its decision; returns what the block
      # returned. `outcome` names the method that reads the decision off that
      # result (Action Policy's `value`); by default the result is the
      # decision. An exception inside the rule is stamped as a deny and
      # re-raised.
      def observe(policy:, rule:, record:, enforced:, entry_point: nil, outcome: nil)
        result = yield
        decision(policy: policy, rule: rule, record: record, allowed: outcome ? result.public_send(outcome) : result,
                 enforced: enforced, entry_point: entry_point)
        result
      rescue StandardError => e
        decision(policy: policy, rule: rule, record: record, allowed: false, raised: e.class.name,
                 enforced: enforced, entry_point: entry_point)
        raise
      end

      def decision(policy:, rule:, record:, allowed:, enforced:, raised: nil, entry_point: nil)
        checked!
        facts = @facts
        store = @store
        return unless active? && facts && store

        store.record(facts.stamp(
                       policy: policy, rule: rule.to_s, record: record, allowed: allowed ? true : false,
                       raised: raised, enforced: enforced, entry_point: entry_point || current_request&.entry_point
                     ))
      rescue StandardError => e
        warn_once(e)
      end

      # Warns once per distinct error that a stamp was dropped; hooks call it
      # so that a fact they cannot read never breaks the app.
      def warn_once(error)
        warned = @warned ||= {}
        key = "#{error.class}: #{error.message}"
        return if warned[key]

        warned[key] = true
        Kernel.warn("hallmark: dropped a stamp: #{key}")
      end

      private

      def install_libraries
        if defined?(::ActionPolicy::Policy::Core)
          require_relative "collectors/action_policy"
          ActionPolicyHook.install
        end
        if defined?(::Pundit::Authorization)
          require_relative "collectors/pundit"
          PunditHook.install
        end
        if defined?(::DeclarativePolicy::Base)
          require_relative "collectors/declarative_policy"
          DeclarativePolicyHook.install
        end
        return unless defined?(::ActiveSupport.on_load)

        require_relative "collectors/controller"
        ::ActiveSupport.on_load(:action_controller) { ControllerHook.attach(self) }
      end
    end

    # Reads the mapped facts off a live policy and record.
    class Facts
      attr_reader :mapping

      def initialize(mapping)
        @mapping = mapping
      end

      def stamp(policy:, rule:, record:, allowed:, raised:, enforced:, entry_point:)
        user = principal(policy)
        current = current_tenant(policy)
        base = {
          entry_point: entry_point, policy: policy.class.name.to_s, rule: rule, enforced: enforced,
          decision: allowed ? "allow" : "deny", raised: raised, logged_in: !user.nil?,
          roles: outside_roles(user), current_roles: current_roles(user, current)
        }
        # Class-level: a class, a name or nothing stands in for the record.
        # `Symbol#name` gives the name itself ("dashboard", "global").
        return Stamp.new(**base, resource: record&.name, class_level: true) if recordless?(record)

        Stamp.new(**base, **record_facts(record, user, current, base), class_level: false)
      end

      private

      # A rule checked with no record: nil, a class (`authorize Link`), or a
      # Symbol, the subject of a headless Pundit or Action Policy policy
      # (`authorize :dashboard`) and of a DeclarativePolicy global ability
      # (`:global`). No library uses a String as a name, so a String is a record.
      def recordless?(record) = record.nil? || record.is_a?(Module) || record.is_a?(Symbol)

      def principal(policy)
        user = read(@mapping.principal_source, policy)
        return nil if user.nil?
        return user if user.class.ancestors.any? { |ancestor| ancestor.name == @mapping.principal_name }

        raise ConfigurationError, "#{policy.class.name} gave a #{user.class.name} as its user, not a " \
                                  "#{@mapping.principal_name}; set `principal \"#{@mapping.principal_name}\", from:`"
      end

      def current_tenant(policy)
        source = @mapping.current_tenant_source
        return nil unless source && @mapping.tenancy
        return read(source, policy) unless source.is_a?(Symbol) && !policy.respond_to?(source)
        return policy.authorization_context[source] if policy.respond_to?(:authorization_context)

        raise ConfigurationError, "#{policy.class.name} has no `#{source}` to read the current tenant from"
      end

      # `base` holds the facts read so far: the policy, the rule and the
      # roles held outside tenants.
      def record_facts(record, user, current, base)
        resource = mapping_for(record)
        return { resource: record.class.name } unless resource

        tenant = tenant_facts(resource, record, user, current)
        counting = tenant[:record_roles] || base.fetch(:roles)
        op = @mapping.op_for(base.fetch(:policy), base.fetch(:rule))
        {
          resource: resource.name,
          owner: (owned_by?(resource, record, user) if resource.owned?),
          public_record: public?(resource, record),
          granted: granted?(resource, op, counting),
          permitted: (permitted?(resource, record, user, op) if resource.permits?),
          **tenant
        }
      end

      def tenant_facts(resource, record, user, current)
        return {} unless resource.tenanted?

        tenant = read(resource.tenant, record)
        # A record with no tenant (`tenant_optional:`) counts the roles held
        # outside tenants, as the catalog's `rolesFor` does.
        return { member: false, in_current_tenant: nil, record_roles: nil } if tenant.nil?

        roles = user ? roles_in(user, tenant) : []
        { member: !roles.empty?, in_current_tenant: (tenant == current if current), record_roles: roles }
      end

      def outside_roles(user) = user ? names(read(@mapping.principal_roles, user)) : []

      def current_roles(user, current)
        roles_in(user, current) if @mapping.tenancy && user && current
      end

      # Whether a mapped grant covers the rule's op for the roles that count
      # for the record.
      def granted?(resource, op, counting)
        @mapping.grants.any? do |grant|
          grant.resource == resource.name && grant.op == op && counting.include?(grant.role)
        end
      end

      # Whether the user holds an explicit permission on the record for the
      # rule's op: `permits:` gives true for every op, or the ops.
      def permitted?(resource, record, user, op)
        return false if user.nil? || op.nil?

        ops = read(resource.permits, user, with: record)
        return false unless ops
        return true if ops == true

        Array(ops).map(&:to_sym).include?(op)
      end

      def mapping_for(record)
        record.class.ancestors.each do |ancestor|
          resource = ancestor.name && @mapping.resources[ancestor.name]
          return resource if resource
        end
        nil
      end

      def owned_by?(resource, record, user)
        return false if user.nil?

        owner = resource.owner ? read(resource.owner, record) : record
        owner == user
      end

      def public?(resource, record)
        condition = resource.public_if
        return true if condition == true
        return false if condition.nil? || condition == false

        read(condition, record) ? true : false
      end

      # A user's roles in a tenant, plus the `self:` role when the user is
      # the tenant.
      def roles_in(user, tenant)
        tenancy = @mapping.tenancy
        return [] unless tenancy

        roles = names(read(tenancy.roles_in, user, with: tenant))
        self_role = tenancy.self_role
        roles |= [self_role] if self_role && user == tenant
        roles.sort
      end

      def names(value) = Array(value).map(&:to_s).uniq.sort

      # A mapping option read off an object: a method name, or a lambda
      # taking the object. `roles_in:` also passes the tenant, and `permits:`
      # the record.
      def read(source, object, with: nil)
        case source
        when nil then nil
        when Proc then call(source, object, with)
        else
          name = source.to_s
          unless object.respond_to?(name)
            raise ConfigurationError,
                  "#{object.class.name} has no `#{name}` for the mapping"
          end

          with.nil? ? object.public_send(name) : object.public_send(name, with)
        end
      end

      def call(source, object, with)
        return source.call if source.arity.zero?

        with.nil? ? source.call(object) : source.call(object, with)
      end
    end
  end
end
