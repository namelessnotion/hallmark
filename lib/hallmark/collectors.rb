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
  #                      Pundit::Authorization, and a module wrapping the
  #                      rules on each policy class, for direct calls
  #   DeclarativePolicy  prepends `allowed?` on DeclarativePolicy::Base
  #   Grape              prepends `run` on Grape::Endpoint to name the entry
  #                      point (GitLab's REST API)
  #   graphql-ruby       a `trace_with` module (2.x) or a `tracer` (1.x) on
  #                      each schema, naming field paths as entry points and
  #                      stamping types' `authorized?`
  #   Action Controller  an `around_action` that flags entry points finishing
  #                      without an authorization call (threat 10)
  #
  # The Railtie installs them in the test environment. A hook never breaks
  # the app: a fact that cannot be read drops the stamp with a warning.
  #
  # The hot path (docs/PLAN.md, "Runtime modes and performance budget";
  # measured by `rake bench`): whether to stamp is decided before any fact
  # is read, once per request (all of a request's decisions are stamped or
  # none) and per decision outside one; a request reads each user's roles
  # in each tenant once.
  module Collectors
    # The entry point a request is running, whether it called any rule,
    # whether its decisions are stamped, the roles read so far in it
    # (`Facts#roles_in`), by user and then tenant, compared by identity, and
    # the object serving it (a controller), which inner entry points share.
    # The entry point is a String, or a callable that names it when a
    # decision is stamped (a GraphQL query's field paths).
    Request = Struct.new(:entry_point, :checked, :halted, :sampled, :roles, :host, keyword_init: true) do
      def entry_point_name
        name = entry_point
        name.is_a?(String) ? name : name.call
      end
    end

    # A policy-like stand-in for a check that has no policy object, such as
    # a GraphQL type's `authorized?`: the name the stamp gives the policy,
    # and the user and current tenant read elsewhere (the query's context).
    ContextPolicy = Struct.new(:name, :user, :current_tenant)

    # The fiber-local a decision sets, so a hook can tell whether a policy
    # library decided while a block ran (`GraphqlHook.authorized`).
    DECIDED = :hallmark_decided

    class << self
      attr_reader :store, :facts

      # `sample_rate` is the share of requests (and of decisions outside a
      # request) whose decisions are stamped, from 0.0 to 1.0.
      def install!(mapping: Hallmark.configuration.mapping, store: StampStore.new(Hallmark.configuration.stamps),
                   sample_rate: 1.0)
        unless mapping
          raise ConfigurationError,
                "the collectors need a mapping; declare one with `Hallmark.configure { |c| c.map { ... } }`"
        end
        unless sample_rate.between?(0, 1)
          raise ConfigurationError, "the sample rate must be a number from 0 to 1, not #{sample_rate.inspect}"
        end

        @sample_rate = sample_rate.to_f
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

      # Whether to collect: the configured mode when set (test, shadow or
      # sampled), else only in the test environment.
      def enabled?(mode, environment) = mode ? Configuration::COLLECTING.include?(mode) : environment == "test"

      def flush = @store&.flush

      # Runs a block as one entry point, such as "LinksController#update",
      # served by `host` (the controller). An entry point inside another
      # takes the outer one's sampling, role reads and host, and a check
      # made in it counts as the outer one's too.
      def within_entry_point(name, host: nil)
        previous = Thread.current[:hallmark_request]
        request = Request.new(entry_point: name, checked: false, halted: false,
                              sampled: previous ? previous.sampled : sample?, roles: previous&.roles,
                              host: host || previous&.host)
        Thread.current[:hallmark_request] = request
        begin
          yield request
        ensure
          previous.checked = true if previous && request.checked
          Thread.current[:hallmark_request] = previous
        end
      end

      def current_request = Thread.current[:hallmark_request]

      # Whether to stamp the decision being made: the collectors are on, and
      # the current request is sampled, or outside a request, this decision
      # is. Hooks ask before reading anything off the policy; outside a
      # request each call rolls again, so ask once per decision.
      def recording?
        return false unless active?

        request = current_request
        request ? request.sampled : sample?
      end

      # Marks the current request as authorized without a decision to stamp:
      # a list scope, or an explicit skip such as Pundit's `skip_authorization`.
      def checked!
        Thread.current[DECIDED] = true
        request = current_request
        request.checked = true if request
      end

      # Records an entry point that finished without an authorization call,
      # with the response status and the HTTP verb when a controller knows them.
      def unchecked!(entry_point, status: nil, verb: nil)
        return unless active?

        @store&.record(Unchecked.new(entry_point: entry_point, status: status, verb: verb))
      end

      # Records a GraphQL request whose context's current tenant is not the
      # controller's (G6).
      def context_mismatch!(mismatch)
        return unless active?

        @store&.record(mismatch)
      end

      # Runs one rule and stamps its decision; returns what the block
      # returned. `outcome` names the method that reads the decision off that
      # result (Action Policy's `value`); by default the result is the
      # decision. An exception inside the rule is stamped as a deny and
      # re-raised. A decision not sampled still counts as a check.
      def observe(policy:, rule:, record:, enforced:, entry_point: nil, outcome: nil)
        unless recording?
          begin
            return yield
          ensure
            checked!
          end
        end

        result = yield
        decision(policy: policy, rule: rule, record: record, allowed: outcome ? result.public_send(outcome) : result,
                 enforced: enforced, entry_point: entry_point)
        result
      rescue StandardError => e
        decision(policy: policy, rule: rule, record: record, allowed: false, raised: e.class.name,
                 enforced: enforced, entry_point: entry_point)
        raise
      end

      # Stamps a decision when the collectors are on. Callers ask
      # `recording?` first; this does not sample again.
      def decision(policy:, rule:, record:, allowed:, enforced:, raised: nil, entry_point: nil)
        checked!
        facts = @facts
        store = @store
        return unless active? && facts && store

        stamp = facts.stamp(policy: policy, rule: rule_name(rule), record: record, allowed: allowed ? true : false,
                            raised: raised, enforced: enforced,
                            entry_point: entry_point || current_request&.entry_point_name)
        record(store, stamp, facts, policy, record)
      rescue StandardError => e
        warn_once(e)
      end

      # A rule's name as a String. `Symbol#name` is the Symbol's own frozen
      # String, where `to_s` would copy it on every decision.
      def rule_name(rule) = rule.is_a?(Symbol) ? rule.name : rule.to_s

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

      # Hands the stamp to the store, with the ids it was seen with when the
      # store records them.
      def record(store, stamp, facts, policy, record)
        store.record(stamp, example: (facts.example(policy, record) if store.ids?))
      end

      # A rate of 0 never samples: `rand` is never below it.
      def sample?
        rate = @sample_rate || 1.0
        rate >= 1.0 || Kernel.rand < rate
      end

      def install_libraries
        install_policy_libraries
        if defined?(::Grape::Endpoint)
          require_relative "collectors/grape"
          GrapeHook.install
        end
        if defined?(::GraphQL::Schema)
          require_relative "collectors/graphql"
          GraphqlHook.install
        end
        return unless defined?(::ActiveSupport.on_load)

        require_relative "collectors/controller"
        ::ActiveSupport.on_load(:action_controller) { ControllerHook.attach(self) }
      end

      def install_policy_libraries
        if defined?(::ActionPolicy::Policy::Core)
          require_relative "collectors/action_policy"
          ActionPolicyHook.install
        end
        if defined?(::Pundit::Authorization)
          require_relative "collectors/pundit"
          PunditHook.install
        end
        return unless defined?(::DeclarativePolicy::Base)

        require_relative "collectors/declarative_policy"
        DeclarativePolicyHook.install
      end
    end

    # Reads the mapped facts off a live policy and record. One instance
    # serves every thread; its caches hold what the mapping fixes once the
    # collectors are installed (which classes are the principal and which
    # resource a class maps to, each rule's op), so a race only computes an
    # entry twice.
    class Facts
      attr_reader :mapping

      def initialize(mapping)
        @mapping = mapping
        @principal_classes = {}.compare_by_identity
        @resources = {}.compare_by_identity
        @ops = {}
      end

      # Fills the stamp in place rather than merging Hashes of facts, so
      # the Stamp and its role lists are most of what a decision allocates.
      def stamp(policy:, rule:, record:, allowed:, raised:, enforced:, entry_point:)
        user = principal(policy)
        current = current_tenant(policy)
        request = Collectors.current_request
        roles = request && (request.roles ||= {}.compare_by_identity)
        name = policy.is_a?(ContextPolicy) ? policy.name : policy.class.name.to_s
        outside = outside_roles(user, roles)
        stamp = new_stamp(entry_point: entry_point, policy: name, rule: rule, enforced: enforced, allowed: allowed,
                          raised: raised, logged_in: !user.nil?, roles: outside)
        # Class-level: a class, a name or nothing stands in for the record.
        # `Symbol#name` gives the name itself ("dashboard", "global").
        if recordless?(record)
          stamp.resource = record&.name
          stamp.class_level = true
        else
          record_facts(stamp, record, user, current, roles, op: op_for(name, rule), outside: outside)
          stamp.class_level = false
        end
        stamp.current_roles = current_roles(stamp, user, current, roles)
        stamp
      end

      # The user, record and current tenant of a decision, as references
      # the stamp store hashes (docs/adr/0004). Read again rather than kept
      # from `stamp`: only stores that record ids ask, and the readers are
      # the policy's own.
      def example(policy, record)
        Example.new(user: Example.ref(principal(policy)), record: (Example.ref(record) unless recordless?(record)),
                    tenant: Example.ref(current_tenant(policy)))
      end

      private

      # The decision's own fields. Set one by one: `Stamp.new` with keywords
      # would build a Hash of them first.
      def new_stamp(entry_point:, policy:, rule:, enforced:, allowed:, raised:, logged_in:, roles:)
        stamp = Stamp.new
        stamp.entry_point = entry_point
        stamp.policy = policy
        stamp.rule = rule
        stamp.enforced = enforced
        stamp.decision = allowed ? "allow" : "deny"
        stamp.raised = raised
        stamp.logged_in = logged_in
        stamp.roles = roles
        stamp
      end

      # A rule checked with no record: nil, a class (`authorize Link`), or a
      # Symbol, the subject of a headless Pundit or Action Policy policy
      # (`authorize :dashboard`) and of a DeclarativePolicy global ability
      # (`:global`). No library uses a String as a name, so a String is a record.
      def recordless?(record) = record.nil? || record.is_a?(Module) || record.is_a?(Symbol)

      def principal(policy)
        user = policy.is_a?(ContextPolicy) ? policy.user : read(@mapping.principal_source, policy)
        return nil if user.nil?

        klass = user.class
        known = @principal_classes[klass]
        if known.nil?
          known = klass.ancestors.any? { |ancestor| ancestor.name == @mapping.principal_name }
          @principal_classes[klass] = known
        end
        return user if known
        if policy.is_a?(ContextPolicy)
          raise ConfigurationError, "the GraphQL context gave a #{user.class.name} as its user, not a " \
                                    "#{@mapping.principal_name}; set `graphql current_user:`"
        end

        raise ConfigurationError, "#{policy.class.name} gave a #{user.class.name} as its user, not a " \
                                  "#{@mapping.principal_name}; set `principal \"#{@mapping.principal_name}\", from:`"
      end

      def current_tenant(policy)
        source = @mapping.current_tenant_source
        return nil unless @mapping.tenancy
        return policy.current_tenant if policy.is_a?(ContextPolicy)
        return nil unless source
        return read(source, policy) unless source.is_a?(Symbol) && !policy.respond_to?(source)
        return policy.authorization_context[source] if policy.respond_to?(:authorization_context)

        raise ConfigurationError, "#{policy.class.name} has no `#{source}` to read the current tenant from"
      end

      # The record's facts, onto the stamp. `op` is the rule's, and
      # `outside` the roles the user holds outside tenants.
      def record_facts(stamp, record, user, current, roles, op:, outside:)
        resource = mapping_for(record)
        stamp.resource = resource ? resource.name : record.class.name
        return unless resource

        held = tenant_facts(stamp, resource, record, user, current, roles: roles)
        stamp.owner = owned_by?(resource, record, user) if resource.owned?
        stamp.public_record = public?(resource, record)
        stamp.granted = granted?(resource, op, held || outside)
        stamp.permitted = permitted?(resource, record, user, op) if resource.permits?
      end

      # The tenant facts, onto the stamp; returns the user's roles in the
      # record's tenant, nil when the record has none.
      def tenant_facts(stamp, resource, record, user, current, roles:)
        return nil unless resource.tenanted?

        tenant = read(resource.tenant, record)
        # A record with no tenant (`tenant_optional:`) counts the roles held
        # outside tenants, as the catalog's `rolesFor` does.
        if tenant.nil?
          stamp.member = false
          stamp.outside_tenants = true
          return nil
        end

        held = user ? roles_in(user, tenant, roles) : []
        stamp.member = !held.empty?
        stamp.in_current_tenant = (tenant == current if current)
        stamp.outside_tenants = false if resource.tenant_optional?
        stamp.record_roles = held
        # Kept for `current_roles`: the same tenant need not be read twice.
        stamp.current_roles = held if current && tenant.equal?(current)
        held
      end

      def outside_roles(user, roles)
        return [] unless user
        return names(read(@mapping.principal_roles, user)) unless roles

        (roles[user] ||= {}.compare_by_identity)[:outside] ||= names(read(@mapping.principal_roles, user))
      end

      # The roles in the current tenant; `tenant_facts` has set them already
      # when the record lives there.
      def current_roles(stamp, user, current, roles)
        return nil unless @mapping.tenancy && user && current

        stamp.current_roles || roles_in(user, current, roles)
      end

      # A rule's op, by policy and rule name, as the mapping and the name give it.
      def op_for(policy, rule)
        ops = @ops[policy] ||= {}
        ops.fetch(rule) { ops[rule] = @mapping.op_for(policy, rule) }
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

      # The mapped resource of the record's class or its nearest ancestor;
      # false in the cache for a class no resource maps.
      def mapping_for(record)
        klass = record.class
        cached = @resources[klass]
        return cached || nil unless cached.nil?

        resources = @mapping.resources
        resource = klass.ancestors.lazy.filter_map { |ancestor| ancestor.name && resources[ancestor.name] }.first
        @resources[klass] = resource || false
        resource
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
      # the tenant; read once per request (`roles`, the request's reads).
      def roles_in(user, tenant, roles = nil)
        return read_roles_in(user, tenant) unless roles

        (roles[user] ||= {}.compare_by_identity)[tenant] ||= read_roles_in(user, tenant)
      end

      def read_roles_in(user, tenant)
        tenancy = @mapping.tenancy
        return [] unless tenancy

        held = names(read(tenancy.roles_in, user, with: tenant))
        self_role = tenancy.self_role
        return held unless self_role && user == tenant && !held.include?(self_role)

        (held + [self_role]).sort!.freeze
      end

      # Role names, as sorted, distinct Strings. Frozen: stamps of one
      # request share them.
      def names(value)
        list = Array(value).map(&:to_s)
        list.uniq!
        list.sort!
        list.freeze
      end

      # A mapping option read off an object: a method name, or a lambda
      # taking the object. `roles_in:` also passes the tenant, and `permits:`
      # the record.
      def read(source, object, with: nil)
        case source
        when nil then nil
        when Proc then call(source, object, with)
        else
          unless object.respond_to?(source)
            raise ConfigurationError,
                  "#{object.class.name} has no `#{source}` for the mapping"
          end

          with.nil? ? object.public_send(source) : object.public_send(source, with)
        end
      end

      def call(source, object, with)
        return source.call if source.arity.zero?

        with.nil? ? source.call(object) : source.call(object, with)
      end
    end
  end
end
