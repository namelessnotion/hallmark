# typed: strict
# frozen_string_literal: true

module Hallmark
  # The one thing a developer must write: how application types correspond
  # to the catalog's types. Everything Hallmark cannot infer from this is a
  # modeling choice made explicit here rather than a silent assumption.
  #
  # Class arguments accept a class constant or its name as a string; both
  # normalize to the class name.
  #
  # Options that take a Symbol or a lambda (`from:`, `roles:`, `roles_in:`,
  # `current_tenant`) tell the collectors how to read facts at run time; the
  # model never calls them.
  class Mapping
    include Guard::DSL

    KINDS = %i[object profile].freeze

    Resource = Struct.new(:name, :owner, :kind, :public_if, :tenant, :tenant_optional, :permits,
                          keyword_init: true) do
      def alloy_sig = Naming.resource_sig(name, kind)
      def owned? = kind == :profile || !owner.nil?
      def public? = !public_if.nil? && public_if != false
      def always_public? = public_if == true
      def tenanted? = !tenant.nil?
      def tenant_optional? = tenant_optional == true
      def permits? = !permits.nil?
    end

    Grant = Struct.new(:role, :op, :resource, keyword_init: true) do
      def alloy_sig = "Grant_#{Naming.identifier(role)}_#{op}_#{Naming.identifier(resource)}"
    end

    # The class whose records are tenants, and how memberships in it are
    # stored. `self_role` is set when the tenant class is the principal class
    # (a Gumroad seller is a User): each tenant then holds that role in itself.
    # `roles_in` reads a user's roles in one tenant at run time.
    Tenancy = Struct.new(:name, :membership, :member, :roles, :self_role, :roles_in, keyword_init: true) do
      def principals? = !self_role.nil?
    end

    # A per-rule override: the rule's op, a hand-written guard, or both, and
    # the resource it checks when no stamp shows it.
    Rule = Struct.new(:policy, :name, :op, :guard, :resource, keyword_init: true) do
      def key = "#{policy}##{name}"
    end

    OPS = %i[read write].freeze

    # Rules that only read, by the Pundit and Action Policy naming convention
    # (`edit?` only renders a form); every other `?` rule writes.
    READ_RULES = %w[index? show? edit?].freeze

    attr_reader :principal_name, :principal_source, :principal_roles, :resources, :grants, :tenancy,
                :current_tenant_source, :platform_roles, :rules, :unchecked_allowed, :terms

    def initialize
      @principal_name = "User"
      @principal_source = :user
      @principal_roles = nil
      @resources = {}
      @grants = []
      @tenancy = nil
      @current_tenant_source = nil
      @platform_roles = []
      @rules = {}
      @unchecked_allowed = []
      @terms = {}
    end

    # An intended permission: every holder of `role` may `op` every record of
    # `resource` (the catalog's explicit-permission pattern). For a resource
    # that lives in a tenant, the role counts only when held in the record's
    # tenant.
    #
    #   grant :moderator, :write, "Post"
    def grant(role, op, resource)
      raise ConfigurationError, "grant op must be :read or :write, not #{op.inspect}" unless OPS.include?(op)

      @grants << Grant.new(role: role.to_s, op: op, resource: Naming.class_name(resource))
    end

    # The application class that represents signed-in users (default "User").
    #
    # from:  how a collector finds the user on a policy: a reader such as
    #        :user (the default for Pundit, Action Policy and
    #        DeclarativePolicy), or a lambda taking the policy
    # roles: the user's roles outside any tenant, as a method name on the
    #        user or a lambda taking the user; nil when there are none
    def principal(name, from: :user, roles: nil)
      @principal_name = Naming.class_name(name)
      @principal_source = from
      @principal_roles = roles
    end

    # The class whose records are tenants, for apps where a user holds roles
    # per tenant (an organization, a group, a Gumroad seller).
    #
    # membership: class holding one user's roles in one tenant
    # member:     association on the membership naming the user
    # roles:      attribute on the membership naming its role or roles
    # self:       when the tenant class is the principal class, the role each
    #             tenant holds in itself (Gumroad: `self: :owner`)
    # roles_in:   for the collectors, a user's roles in one tenant: a lambda
    #             taking the user and the tenant, or a method name on the user
    #             that takes the tenant; the `self:` role is added on its own
    #
    #   tenant "User", membership: "TeamMembership", member: :user, roles: :role, self: :owner,
    #                  roles_in: ->(user, seller) { user.team_roles_for(seller) }
    def tenant(name, membership: nil, member: :user, roles: :role, self: nil, roles_in: nil)
      raise ConfigurationError, "tenant is mapped twice; Hallmark supports one tenant class" if @tenancy

      self_role = binding.local_variable_get(:self)
      @tenancy = Tenancy.new(
        name: Naming.class_name(name),
        membership: membership && Naming.class_name(membership),
        member: member,
        roles: roles,
        self_role: self_role&.to_s,
        roles_in: roles_in
      )
    end

    # Where a request's current tenant comes from, such as :seller for a
    # policy context's `seller`, or a lambda or block. Recorded for the
    # collectors; the model checks guards against every possible current tenant.
    def current_tenant(source = nil, &block)
      @current_tenant_source = source || block
    end

    # Roles that intentionally grant access across tenants, such as the
    # vendor's support staff. Holders may do anything in any tenant.
    def platform_role(*names)
      @platform_roles |= names.map(&:to_s)
    end

    # owner:     association naming the owning user (e.g. :author), or nil when
    #            the record has no owner
    # kind:      :profile when each record describes one user (the user's own
    #            profile or account)
    # public_if: predicate under which a record is public (e.g. :published?),
    #            true when every record is public, nil when none is
    # tenant:    association naming the record's tenant (e.g. :organization),
    #            or nil when the record lives outside tenants
    # tenant_optional: true when some records have no tenant (a Forem article
    #            posted under an organization, or under its author alone);
    #            roles then count outside tenants for those records
    # permits:   for the collectors, the ops a user holds an explicit
    #            permission for on one record, outside any role or tenant
    #            (a collaborator, a share): a lambda taking the user and the
    #            record, or a method name on the user that takes the record,
    #            returning true for every op, or :read, :write or a list
    #
    #   resource "Link", tenant: :user, permits: ->(user, link) { user.collaborator_for?(link) }
    def resource(name, owner: nil, kind: :object, public_if: nil, tenant: nil, tenant_optional: false, permits: nil)
      raise ConfigurationError, "unknown resource kind: #{kind}" unless KINDS.include?(kind)

      key = Naming.class_name(name)
      raise ConfigurationError, "resource #{key} is mapped twice" if @resources.key?(key)
      raise ConfigurationError, "resource #{key} has `tenant_optional:` but no `tenant:`" if tenant_optional && !tenant

      @resources[key] = Resource.new(name: key, owner: owner, kind: kind, public_if: public_if, tenant: tenant,
                                     tenant_optional: tenant_optional ? true : false, permits: permits)
    end

    # Overrides one rule of a policy: its op, when the naming convention gets
    # it wrong or the rule has no `?` name (a DeclarativePolicy ability), and
    # a hand-written guard, which replaces the guard inferred from stamps.
    # `resource:` names the record a rule checks, for a hand-written guard on
    # a rule no stamp shows; by default it is the policy's name without
    # "Policy" (LinkPolicy checks Link).
    #
    #   rule "LinkPolicy", :publish?, op: :write
    #   rule "LinkPolicy", :update?, guard: role(:admin, tenant: :current) & in_current_tenant
    def rule(policy, name, op: nil, guard: nil, resource: nil)
      raise ConfigurationError, "rule op must be :read or :write, not #{op.inspect}" unless op.nil? || OPS.include?(op)
      unless guard.nil? || guard.is_a?(Guard)
        raise ConfigurationError,
              "guard for #{policy}##{name} must be a Hallmark::Guard"
      end

      entry = Rule.new(policy: Naming.class_name(policy), name: name.to_s, op: op, guard: guard,
                       resource: resource && Naming.class_name(resource))
      raise ConfigurationError, "rule #{entry.key} is mapped twice" if @rules.key?(entry.key)

      @rules[entry.key] = entry
    end

    # The op a rule performs: the mapping's override, else the naming
    # convention for `?` rules, else nil (the rule needs a `rule` declaration).
    def op_for(policy, name)
      declared = @rules["#{policy}##{name}"]&.op
      return declared if declared
      return nil unless name.end_with?("?")

      READ_RULES.include?(name) ? :read : :write
    end

    # What a Ruby expression in policy code means, for the extractor
    # (`Hallmark::Extractor`), when the mapping's other declarations do not
    # say. The source is matched against rule bodies after normalizing
    # spacing, parentheses, `self.` and instance variables (`@seller` reads
    # as `seller`); a comparison matches either way round.
    #
    #   term "user.role_admin_for?(seller)", role(:admin, tenant: :current)
    #   term "user.role_admin_for?(record.user)", role(:admin, tenant: :record)
    def term(source, guard)
      raise ConfigurationError, "the term for #{source} must be a Hallmark::Guard" unless guard.is_a?(Guard)
      raise ConfigurationError, "term #{source} is mapped twice" if @terms.key?(source.to_s)

      @terms[source.to_s] = guard
    end

    # Entry points that may finish without an authorization call, such as a
    # public landing page, so they are not flagged as unchecked (threat 10).
    def allow_unchecked(*entry_points)
      @unchecked_allowed |= entry_points.map(&:to_s)
    end

    def fetch(name)
      key = Naming.class_name(name)
      @resources.fetch(key) do
        raise ConfigurationError, "resource #{key} is not mapped; add `resource \"#{key}\"` to the map block"
      end
    end

    def by_sig(sig)
      @resources.values.find { |resource| resource.alloy_sig == sig }
    end

    # Checks that need the whole map block, since declarations come in any order.
    def validate!
      if (tenancy = @tenancy)
        if tenancy.principals? && tenancy.name != @principal_name
          raise ConfigurationError, "tenant #{tenancy.name} uses `self:`, which needs the tenant class to be " \
                                    "the principal class (#{@principal_name})"
        end
      elsif (resource = @resources.values.find(&:tenanted?))
        raise ConfigurationError, "resource #{resource.name} has a tenant, but the map block declares no `tenant`"
      end
      @rules.each_value { |rule| validate_rule!(rule) }
      self
    end

    # What the collectors need beyond `validate!`: a way to read tenant roles.
    def validate_collection!
      validate!
      if (tenancy = @tenancy) && tenancy.roles_in.nil?
        raise ConfigurationError, "tenant #{tenancy.name} needs `roles_in:` so the collectors can read a user's " \
                                  "roles in a tenant"
      end
      self
    end

    private

    # `dup` gives a mapping the DSL can extend without changing the source:
    # the collections the declarations add to are copied. The Structs inside
    # them (Resource, Grant, Tenancy, Rule), the frozen Guards and the lambdas
    # stay shared by reference, since nothing changes them once built.
    def initialize_copy(source)
      super
      @resources = @resources.dup
      @grants = @grants.dup
      @rules = @rules.dup
      @platform_roles = @platform_roles.dup
      @unchecked_allowed = @unchecked_allowed.dup
      @terms = @terms.dup
    end

    # A rule's declared resource must be mapped.
    def validate_rule!(rule)
      name = rule.resource
      fetch(name) if name
    end
  end
end
