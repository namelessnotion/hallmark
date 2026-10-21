# typed: strict

module Hallmark
  class Mapping
    include Guard::DSL

    class Resource
      sig { returns(String) }
      def name; end

      # Association naming the owning user, such as :author
      sig { returns(T.nilable(Symbol)) }
      def owner; end

      sig { returns(Symbol) }
      def kind; end

      # A predicate such as :published?, true when every record is public
      sig { returns(T.nilable(T.any(Symbol, T::Boolean))) }
      def public_if; end

      # Association naming the record's tenant, such as :organization
      sig { returns(T.nilable(Symbol)) }
      def tenant; end

      # True when some records have no tenant
      sig { returns(T.nilable(T::Boolean)) }
      def tenant_optional; end

      # How the collectors read a user's explicit permissions on one record
      sig { returns(Collectors::Source) }
      def permits; end

      # Named boolean attributes for guards read from code
      sig { returns(T::Array[String]) }
      def flags; end

      # When a record is public, over its flags; nil when public_if alone says
      sig { returns(T.nilable(Guard)) }
      def public_when; end

      # The ops the owner may perform outside the record's tenant; nil for none
      sig { returns(T.nilable(T::Array[Symbol])) }
      def owner_outside; end

      sig do
        params(
          name: String,
          owner: T.nilable(Symbol),
          kind: Symbol,
          public_if: T.nilable(T.any(Symbol, T::Boolean)),
          tenant: T.nilable(Symbol),
          tenant_optional: T.nilable(T::Boolean),
          permits: Collectors::Source,
          flags: T::Array[String],
          public_when: T.nilable(Guard),
          owner_outside: T.nilable(T::Array[Symbol])
        ).void
      end
      def initialize(name:, owner:, kind:, public_if:, tenant:, tenant_optional: nil, permits: nil, flags: [],
                     public_when: nil, owner_outside: nil); end

      sig { returns(String) }
      def alloy_sig; end

      sig { returns(T::Array[Symbol]) }
      def owner_outside_ops; end

      sig { returns(T::Boolean) }
      def owned?; end

      sig { returns(T::Boolean) }
      def public?; end

      sig { returns(T::Boolean) }
      def always_public?; end

      sig { returns(T::Boolean) }
      def tenanted?; end

      sig { returns(T::Boolean) }
      def tenant_optional?; end

      sig { returns(T::Boolean) }
      def permits?; end
    end

    class Grant
      sig { returns(String) }
      def role; end

      sig { returns(Symbol) }
      def op; end

      sig { returns(String) }
      def resource; end

      # A guard over the resource's flags limiting the records it covers
      sig { returns(T.nilable(Guard)) }
      def condition; end

      sig { params(role: String, op: Symbol, resource: String, condition: T.nilable(Guard)).void }
      def initialize(role:, op:, resource:, condition: nil); end

      sig { returns(String) }
      def alloy_sig; end
    end

    class PublicAction
      # The policy, or the policies (space-separated) when combined for an entry point
      sig { returns(String) }
      def policy; end

      sig { returns(String) }
      def rule; end

      # :anyone or :signed_in
      sig { returns(Symbol) }
      def audience; end

      # A guard over the resource's flags limiting the records it covers
      sig { returns(T.nilable(Guard)) }
      def condition; end

      sig { params(policy: String, rule: String, audience: Symbol, condition: T.nilable(Guard)).void }
      def initialize(policy:, rule:, audience:, condition: nil); end

      sig { returns(String) }
      def key; end

      sig { params(actions: T::Array[PublicAction]).returns(PublicAction) }
      def self.combine(actions); end
    end

    AUDIENCES = T.let(T.unsafe(nil), T::Array[Symbol])

    class FieldPolicy
      sig { returns(String) }
      def resource; end

      sig { returns(String) }
      def field; end

      sig { returns(Guard) }
      def guard; end

      sig { params(resource: String, field: String, guard: Guard).void }
      def initialize(resource:, field:, guard:); end

      # "User.email"
      sig { returns(String) }
      def key; end
    end

    class Tenancy
      sig { returns(String) }
      def name; end

      # Class name of the membership, such as "TeamMembership"
      sig { returns(T.nilable(String)) }
      def membership; end

      sig { returns(Symbol) }
      def member; end

      sig { returns(Symbol) }
      def roles; end

      # The role each tenant holds in itself when tenants are principals
      sig { returns(T.nilable(String)) }
      def self_role; end

      # How the collectors read a user's roles in a tenant
      sig { returns(Collectors::Source) }
      def roles_in; end

      sig do
        params(
          name: String,
          membership: T.nilable(String),
          member: Symbol,
          roles: Symbol,
          self_role: T.nilable(String),
          roles_in: Collectors::Source
        ).void
      end
      def initialize(name:, membership:, member:, roles:, self_role:, roles_in: nil); end

      sig { returns(T::Boolean) }
      def principals?; end
    end

    class Rule
      sig { returns(String) }
      def policy; end

      sig { returns(String) }
      def name; end

      sig { returns(T.nilable(Symbol)) }
      def op; end

      sig { returns(T.nilable(Guard)) }
      def guard; end

      # The resource the rule checks, when declared
      sig { returns(T.nilable(String)) }
      def resource; end

      sig do
        params(policy: String, name: String, op: T.nilable(Symbol), guard: T.nilable(Guard),
               resource: T.nilable(String)).void
      end
      def initialize(policy:, name:, op:, guard:, resource: nil); end

      # "LinkPolicy#update?"
      sig { returns(String) }
      def key; end
    end

    sig { returns(String) }
    attr_reader :principal_name

    # How the collectors find the user on a policy
    sig { returns(Collectors::Source) }
    attr_reader :principal_source

    # How the collectors read the user's roles outside tenants
    sig { returns(Collectors::Source) }
    attr_reader :principal_roles

    # The controllers' reader of the signed-in user, such as "current_user"
    sig { returns(T.nilable(String)) }
    attr_reader :principal_controller

    # Overrides keyed by "Policy#rule"
    sig { returns(T::Hash[String, Rule]) }
    attr_reader :rules

    sig { returns(T::Array[String]) }
    attr_reader :unchecked_allowed

    # Declared terms for the extractor: Ruby source => guard
    sig { returns(T::Hash[String, Guard]) }
    attr_reader :terms

    # Rule key ("Policy#rule") => its public action
    sig { returns(T::Hash[String, PublicAction]) }
    attr_reader :public_actions

    sig { returns(T::Hash[String, Resource]) }
    attr_reader :resources

    # "Resource.field" => its policy
    sig { returns(T::Hash[String, FieldPolicy]) }
    attr_reader :field_policies

    # Name => restriction, in declaration order
    sig { returns(T::Hash[String, Restriction]) }
    attr_reader :restrictions

    sig { returns(T::Array[Grant]) }
    attr_reader :grants

    sig { returns(T.nilable(Tenancy)) }
    attr_reader :tenancy

    # A context entry such as :seller, or a block
    sig { returns(T.nilable(T.any(String, Symbol, Proc))) }
    attr_reader :current_tenant_source

    # The controllers' reader of the current tenant, such as "current_seller"
    sig { returns(T.nilable(String)) }
    attr_reader :current_tenant_controller

    sig { returns(T::Array[String]) }
    attr_reader :platform_roles

    sig { void }
    def initialize
      @principal_name = T.let(T.unsafe(nil), String)
      @resources = T.let(T.unsafe(nil), T::Hash[String, Resource])
      @grants = T.let(T.unsafe(nil), T::Array[Grant])
      @tenancy = T.let(T.unsafe(nil), T.nilable(Tenancy))
      @current_tenant_source = T.let(T.unsafe(nil), T.nilable(T.any(String, Symbol, Proc)))
      @current_tenant_controller = T.let(T.unsafe(nil), T.nilable(String))
      @platform_roles = T.let(T.unsafe(nil), T::Array[String])
      @principal_source = T.let(T.unsafe(nil), Collectors::Source)
      @principal_roles = T.let(T.unsafe(nil), Collectors::Source)
      @principal_controller = T.let(T.unsafe(nil), T.nilable(String))
      @rules = T.let(T.unsafe(nil), T::Hash[String, Rule])
      @unchecked_allowed = T.let(T.unsafe(nil), T::Array[String])
      @terms = T.let(T.unsafe(nil), T::Hash[String, Guard])
      @public_actions = T.let(T.unsafe(nil), T::Hash[String, PublicAction])
      @field_policies = T.let(T.unsafe(nil), T::Hash[String, FieldPolicy])
      @restrictions = T.let(T.unsafe(nil), T::Hash[String, Restriction])
    end

    sig do
      params(role: T.any(String, Symbol), op: Symbol, resource: T.any(String, Symbol, T::Module[T.anything]),
             when: T.nilable(Guard)).void
    end
    def grant(role, op, resource, when: nil); end

    sig do
      params(policy: T.any(String, Symbol, T::Module[T.anything]), rules: T.any(String, Symbol), audience: Symbol,
             when: T.nilable(Guard)).returns(T::Array[PublicAction])
    end
    def public_action(policy, *rules, audience: :anyone, when: nil); end

    sig { params(rules: T::Array[String]).returns(T.nilable(PublicAction)) }
    def public_action_for(rules); end

    # Checked at run time, since callers without Sorbet can pass anything
    sig { params(condition: T.nilable(Object), what: String).returns(T.nilable(Guard)) }
    def self.flag_condition(condition, what); end

    # `guard` is checked at run time
    sig do
      params(resource: T.any(String, Symbol, T::Module[T.anything]), field: T.any(String, Symbol), guard: Object)
        .returns(FieldPolicy)
    end
    def field_policy(resource, field, guard); end

    sig do
      params(resource: T.any(String, Symbol, T::Module[T.anything]), field: T.nilable(T.any(String, Symbol)))
        .returns(T.nilable(FieldPolicy))
    end
    def field_policy_for(resource, field); end

    sig do
      params(name: T.any(String, Symbol), block: T.nilable(T.proc.bind(Restriction::Builder).void)).returns(Restriction)
    end
    def restrict(name, &block); end

    sig { params(exposure: Exposure).returns(T::Array[Restriction]) }
    def restrictions_for(exposure); end

    # Grants, platform roles, the `self:` role and the roles field policies check
    sig { returns(T::Array[String]) }
    def declared_roles; end

    sig do
      params(name: T.any(String, Symbol, T::Module[T.anything]), from: Collectors::Source, roles: Collectors::Source,
             controller: T.nilable(T.any(String, Symbol))).void
    end
    def principal(name, from: :user, roles: nil, controller: :current_user); end

    sig do
      params(
        name: T.any(String, Symbol, T::Module[T.anything]),
        membership: T.nilable(T.any(String, Symbol, T::Module[T.anything])),
        member: Symbol,
        roles: Symbol,
        self: T.nilable(T.any(String, Symbol)),
        roles_in: Collectors::Source
      ).returns(Tenancy)
    end
    def tenant(name, membership: nil, member: :user, roles: :role, self: nil, roles_in: nil); end

    sig do
      params(
        source: T.nilable(T.any(String, Symbol, Proc)),
        controller: T.nilable(T.any(String, Symbol)),
        block: T.nilable(Proc)
      ).returns(T.nilable(String))
    end
    def current_tenant(source = nil, controller: nil, &block); end

    sig { params(names: T.any(String, Symbol)).returns(T::Array[String]) }
    def platform_role(*names); end

    sig do
      params(
        name: T.any(String, Symbol, T::Module[T.anything]),
        owner: T.nilable(Symbol),
        kind: Symbol,
        public_if: T.nilable(T.any(Symbol, T::Boolean)),
        tenant: T.nilable(Symbol),
        tenant_optional: T::Boolean,
        permits: Collectors::Source,
        flags: T::Array[T.any(String, Symbol)],
        public_when: T.nilable(Guard),
        owner_outside_tenant: T.nilable(T.any(T::Boolean, Symbol, T::Array[Symbol]))
      ).returns(Resource)
    end
    def resource(name, owner: nil, kind: :object, public_if: nil, tenant: nil, tenant_optional: false, permits: nil,
                 flags: [], public_when: nil, owner_outside_tenant: nil); end

    sig do
      params(
        policy: T.any(String, Symbol, T::Module[T.anything]),
        name: T.any(String, Symbol),
        op: T.nilable(Symbol),
        guard: T.nilable(Object),
        resource: T.nilable(T.any(String, T::Module[T.anything]))
      ).returns(Rule)
    end
    def rule(policy, name, op: nil, guard: nil, resource: nil); end

    sig { params(policy: String, name: String).returns(T.nilable(Symbol)) }
    def op_for(policy, name); end

    sig { params(entry_points: T.any(String, Symbol)).returns(T::Array[String]) }
    def allow_unchecked(*entry_points); end

    # Checked at run time, since callers without Sorbet can pass anything
    sig { params(source: T.any(String, Symbol), guard: Object).returns(Guard) }
    def term(source, guard); end

    sig { params(name: T.any(String, Symbol, T::Module[T.anything])).returns(Resource) }
    def fetch(name); end

    sig { params(sig: String).returns(T.nilable(Resource)) }
    def by_sig(sig); end

    sig { returns(T.self_type) }
    def validate!; end

    sig { returns(T.self_type) }
    def validate_collection!; end

    private

    sig { params(source: T.self_type).void }
    def initialize_copy(source); end

    sig { params(key: String, guard: T.nilable(Object), flags: T::Array[String]).void }
    def validate_public_when!(key, guard, flags); end


    sig do
      params(key: String, value: T.nilable(T.any(T::Boolean, Symbol, T::Array[Symbol])), owned: T::Boolean,
             tenanted: T::Boolean).returns(T.nilable(T::Array[Symbol]))
    end
    def owner_outside(key, value, owned:, tenanted:); end

    sig { params(rule: Rule).void }
    def validate_rule!(rule); end

    sig { void }
    def validate_narrowing!; end
  end
end
