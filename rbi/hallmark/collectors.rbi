# typed: strict

module Hallmark
  module Collectors
    # A Symbol (a method name) or a lambda, from the mapping
    Source = T.type_alias { T.nilable(T.any(String, Symbol, Proc)) }

    class Request
      sig { returns(String) }
      def entry_point; end

      sig { returns(T::Boolean) }
      def checked; end

      sig { params(checked: T::Boolean).returns(T::Boolean) }
      def checked=(checked); end

      sig { returns(T::Boolean) }
      def halted; end

      sig { params(halted: T::Boolean).returns(T::Boolean) }
      def halted=(halted); end

      sig { returns(T::Boolean) }
      def sampled; end

      # By user, then by tenant (or :outside for roles held outside tenants).
      sig { returns(T.nilable(T::Hash[T.untyped, T::Hash[T.untyped, T::Array[String]]])) }
      def roles; end

      sig do
        params(roles: T.nilable(T::Hash[T.untyped, T::Hash[T.untyped, T::Array[String]]]))
          .returns(T.nilable(T::Hash[T.untyped, T::Hash[T.untyped, T::Array[String]]]))
      end
      def roles=(roles); end

      sig do
        params(entry_point: String, checked: T::Boolean, halted: T::Boolean, sampled: T::Boolean,
               roles: T.nilable(T::Hash[T.untyped, T::Hash[T.untyped, T::Array[String]]])).void
      end
      def initialize(entry_point:, checked:, halted:, sampled:, roles:); end
    end

    # A request's role reads (`Request#roles`).
    Roles = T.type_alias { T::Hash[T.untyped, T::Hash[T.untyped, T::Array[String]]] }

    @facts = T.let(nil, T.nilable(Facts))
    @sample_rate = T.let(nil, T.nilable(Float))
    @store = T.let(nil, T.nilable(StampStore))
    @warned = T.let(nil, T.nilable(T::Hash[String, T::Boolean]))
    @active = T.let(nil, T.nilable(T::Boolean))

    class << self
      sig { returns(T.nilable(StampStore)) }
      attr_reader :store

      sig { returns(T.nilable(Facts)) }
      attr_reader :facts

      sig { params(mapping: T.nilable(Mapping), store: StampStore, sample_rate: Numeric).returns(T.self_type) }
      def install!(mapping: Hallmark.configuration.mapping, store: StampStore.new(Hallmark.configuration.stamps),
                   sample_rate: 1.0); end

      sig { void }
      def uninstall!; end

      sig { returns(T::Boolean) }
      def active?; end

      sig { params(mode: T.nilable(String), environment: String).returns(T::Boolean) }
      def enabled?(mode, environment); end

      sig { void }
      def flush; end

      sig do
        type_parameters(:R)
          .params(name: String, blk: T.proc.params(request: Request).returns(T.type_parameter(:R)))
          .returns(T.type_parameter(:R))
      end
      def within_entry_point(name, &blk); end

      sig { returns(T.nilable(Request)) }
      def current_request; end

      sig { returns(T::Boolean) }
      def recording?; end

      sig { void }
      def checked!; end

      sig { params(entry_point: String, status: T.nilable(Integer), verb: T.nilable(String)).void }
      def unchecked!(entry_point, status: nil, verb: nil); end

      # Returns what the block returns: a decision, or a library's result object.
      sig do
        params(policy: T.untyped, rule: T.any(String, Symbol), record: T.untyped, enforced: T::Boolean,
               entry_point: T.nilable(String), outcome: T.nilable(Symbol), blk: T.proc.returns(T.untyped))
          .returns(T.untyped)
      end
      def observe(policy:, rule:, record:, enforced:, entry_point: nil, outcome: nil, &blk); end

      sig do
        params(policy: T.untyped, rule: T.any(String, Symbol), record: T.untyped, allowed: T.untyped,
               enforced: T::Boolean, raised: T.nilable(String), entry_point: T.nilable(String)).void
      end
      def decision(policy:, rule:, record:, allowed:, enforced:, raised: nil, entry_point: nil); end

      sig { params(rule: T.untyped).returns(String) }
      def rule_name(rule); end

      sig { params(error: StandardError).void }
      def warn_once(error); end

      private

      sig { returns(T::Boolean) }
      def sample?; end

      sig { void }
      def install_libraries; end
    end

    class Facts
      sig { returns(Mapping) }
      attr_reader :mapping

      sig { params(mapping: Mapping).void }
      def initialize(mapping)
        @mapping = T.let(T.unsafe(nil), Mapping)
        @principal_classes = T.let(T.unsafe(nil), T::Hash[T::Module[T.anything], T::Boolean])
        @resources = T.let(T.unsafe(nil), T::Hash[T::Module[T.anything], T.any(Mapping::Resource, FalseClass)])
        @ops = T.let(T.unsafe(nil), T::Hash[String, T::Hash[String, T.nilable(Symbol)]])
      end

      # `policy` and `record` are the app's objects.
      sig do
        params(policy: T.untyped, rule: String, record: T.untyped, allowed: T::Boolean, raised: T.nilable(String),
               enforced: T::Boolean, entry_point: T.nilable(String)).returns(Stamp)
      end
      def stamp(policy:, rule:, record:, allowed:, raised:, enforced:, entry_point:); end

      private

      sig do
        params(entry_point: T.nilable(String), policy: String, rule: String, enforced: T::Boolean, allowed: T::Boolean,
               raised: T.nilable(String), logged_in: T::Boolean, roles: T::Array[String]).returns(Stamp)
      end
      def new_stamp(entry_point:, policy:, rule:, enforced:, allowed:, raised:, logged_in:, roles:); end

      sig { params(record: T.untyped).returns(T::Boolean) }
      def recordless?(record); end

      sig { params(policy: T.untyped).returns(T.untyped) }
      def principal(policy); end

      sig { params(policy: T.untyped).returns(T.untyped) }
      def current_tenant(policy); end

      sig do
        params(stamp: Stamp, record: T.untyped, user: T.untyped, current: T.untyped, roles: T.nilable(Roles),
               op: T.nilable(Symbol), outside: T::Array[String]).void
      end
      def record_facts(stamp, record, user, current, roles, op:, outside:); end

      sig do
        params(stamp: Stamp, resource: Mapping::Resource, record: T.untyped, user: T.untyped, current: T.untyped,
               roles: T.nilable(Roles)).returns(T.nilable(T::Array[String]))
      end
      def tenant_facts(stamp, resource, record, user, current, roles:); end

      sig { params(user: T.untyped, roles: T.nilable(Roles)).returns(T::Array[String]) }
      def outside_roles(user, roles); end

      sig do
        params(stamp: Stamp, user: T.untyped, current: T.untyped, roles: T.nilable(Roles))
          .returns(T.nilable(T::Array[String]))
      end
      def current_roles(stamp, user, current, roles); end

      sig { params(policy: String, rule: String).returns(T.nilable(Symbol)) }
      def op_for(policy, rule); end

      sig { params(resource: Mapping::Resource, op: T.nilable(Symbol), counting: T::Array[String]).returns(T::Boolean) }
      def granted?(resource, op, counting); end

      sig do
        params(resource: Mapping::Resource, record: T.untyped, user: T.untyped, op: T.nilable(Symbol))
          .returns(T::Boolean)
      end
      def permitted?(resource, record, user, op); end

      sig { params(record: T.untyped).returns(T.nilable(Mapping::Resource)) }
      def mapping_for(record); end

      sig { params(resource: Mapping::Resource, record: T.untyped, user: T.untyped).returns(T::Boolean) }
      def owned_by?(resource, record, user); end

      sig { params(resource: Mapping::Resource, record: T.untyped).returns(T::Boolean) }
      def public?(resource, record); end

      sig { params(user: T.untyped, tenant: T.untyped, roles: T.nilable(Roles)).returns(T::Array[String]) }
      def roles_in(user, tenant, roles = nil); end

      sig { params(user: T.untyped, tenant: T.untyped).returns(T::Array[String]) }
      def read_roles_in(user, tenant); end

      sig { params(value: T.untyped).returns(T::Array[String]) }
      def names(value); end

      sig { params(source: T.any(Source, T::Boolean), object: T.untyped, with: T.untyped).returns(T.untyped) }
      def read(source, object, with: nil); end

      sig { params(source: Proc, object: T.untyped, with: T.untyped).returns(T.untyped) }
      def call(source, object, with); end
    end
  end
end
