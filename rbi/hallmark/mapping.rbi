# typed: strict

module Hallmark
  class Mapping
    include Guard::DSL

    READ_RULES = T.let(T.unsafe(nil), T::Array[String])

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

      sig do
        params(
          name: String,
          owner: T.nilable(Symbol),
          kind: Symbol,
          public_if: T.nilable(T.any(Symbol, T::Boolean)),
          tenant: T.nilable(Symbol),
          tenant_optional: T.nilable(T::Boolean),
          permits: Collectors::Source
        ).void
      end
      def initialize(name:, owner:, kind:, public_if:, tenant:, tenant_optional: nil, permits: nil); end

      sig { returns(String) }
      def alloy_sig; end

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

      sig { params(role: String, op: Symbol, resource: String).void }
      def initialize(role:, op:, resource:); end

      sig { returns(String) }
      def alloy_sig; end
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

    # Overrides keyed by "Policy#rule"
    sig { returns(T::Hash[String, Rule]) }
    attr_reader :rules

    sig { returns(T::Array[String]) }
    attr_reader :unchecked_allowed

    sig { returns(T::Hash[String, Resource]) }
    attr_reader :resources

    sig { returns(T::Array[Grant]) }
    attr_reader :grants

    sig { returns(T.nilable(Tenancy)) }
    attr_reader :tenancy

    # A context entry such as :seller, or a block
    sig { returns(T.nilable(T.any(String, Symbol, Proc))) }
    attr_reader :current_tenant_source

    sig { returns(T::Array[String]) }
    attr_reader :platform_roles

    sig { void }
    def initialize
      @principal_name = T.let(T.unsafe(nil), String)
      @resources = T.let(T.unsafe(nil), T::Hash[String, Resource])
      @grants = T.let(T.unsafe(nil), T::Array[Grant])
      @tenancy = T.let(T.unsafe(nil), T.nilable(Tenancy))
      @current_tenant_source = T.let(T.unsafe(nil), T.nilable(T.any(String, Symbol, Proc)))
      @platform_roles = T.let(T.unsafe(nil), T::Array[String])
      @principal_source = T.let(T.unsafe(nil), Collectors::Source)
      @principal_roles = T.let(T.unsafe(nil), Collectors::Source)
      @rules = T.let(T.unsafe(nil), T::Hash[String, Rule])
      @unchecked_allowed = T.let(T.unsafe(nil), T::Array[String])
    end

    sig { params(role: T.any(String, Symbol), op: Symbol, resource: T.any(String, Symbol, T::Module[T.anything])).void }
    def grant(role, op, resource); end

    sig do
      params(name: T.any(String, Symbol, T::Module[T.anything]), from: Collectors::Source, roles: Collectors::Source).void
    end
    def principal(name, from: :user, roles: nil); end

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
        block: T.nilable(Proc)
      ).returns(T.nilable(T.any(String, Symbol, Proc)))
    end
    def current_tenant(source = nil, &block); end

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
        permits: Collectors::Source
      ).returns(Resource)
    end
    def resource(name, owner: nil, kind: :object, public_if: nil, tenant: nil, tenant_optional: false, permits: nil); end

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

    sig { params(rule: Rule).void }
    def validate_rule!(rule); end
  end
end
