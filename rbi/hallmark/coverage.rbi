# typed: strict

module Hallmark
  class Coverage
    class Dim
      # A Stamp field: :logged_in, :public_record, :owner, :permitted,
      # :outside_tenants, :in_current_tenant, :record_roles, :current_roles
      # or :roles
      sig { returns(Symbol) }
      def kind; end

      sig { returns(String) }
      def label; end

      # True for a role-set dimension, nil for a boolean one
      sig { returns(T.nilable(T::Boolean)) }
      def roles; end

      sig { params(kind: Symbol, label: String, roles: T.nilable(T::Boolean)).void }
      def initialize(kind:, label:, roles: nil); end
    end

    # A boolean, or a sorted set of role names
    Value = T.type_alias { T.any(T::Boolean, T::Array[String]) }
    Assignment = T.type_alias { T::Hash[Dim, Value] }

    class Gap
      sig { returns(String) }
      def rule; end

      sig { returns(String) }
      def resource; end

      sig { returns(Symbol) }
      def op; end

      sig { returns(Integer) }
      def allows; end

      sig { returns(Integer) }
      def denies; end

      sig { returns(T::Array[String]) }
      def combinations; end

      sig do
        params(rule: String, resource: String, op: Symbol, allows: Integer, denies: Integer,
               combinations: T::Array[String]).void
      end
      def initialize(rule:, resource:, op:, allows:, denies:, combinations:); end
    end

    class Opaque
      sig { returns(String) }
      def rule; end

      sig { returns(String) }
      def call; end

      sig { returns(T.nilable(String)) }
      def location; end

      sig { params(rule: String, call: String, location: T.nilable(String)).void }
      def initialize(rule:, call:, location: nil); end

      sig { returns(String) }
      def to_s; end
    end

    sig { returns(T::Array[Gap]) }
    attr_reader :gaps

    sig { returns(T::Array[String]) }
    attr_reader :never_allowed

    sig { returns(T::Array[String]) }
    attr_reader :unreached

    sig { returns(T::Array[String]) }
    attr_reader :class_level

    sig { returns(T::Array[String]) }
    attr_reader :without_op

    sig { returns(T::Array[String]) }
    attr_reader :unmapped

    # Entry points that redirected a GET or HEAD without an authorization
    # call, excused from threat 10 because other requests to them did authorize
    sig { returns(T::Array[String]) }
    attr_reader :redirected

    # Calls inside rules that the extractor could not read
    sig { returns(T::Array[Opaque]) }
    attr_reader :opaque

    # Rules read from code that no stamp shows
    sig { returns(T::Array[String]) }
    attr_reader :code_only

    sig { params(mapping: Mapping, stamps: T::Array[Stamp]).void }
    def initialize(mapping, stamps)
      @mapping = T.let(T.unsafe(nil), Mapping)
      @universe = T.let(T.unsafe(nil), T::Array[String])
      @dims = T.let(T.unsafe(nil), T::Array[Dim])
      @domains = T.let(T.unsafe(nil), T::Hash[Dim, T::Array[T::Array[String]]])
      @gaps = T.let(T.unsafe(nil), T::Array[Gap])
      @never_allowed = T.let(T.unsafe(nil), T::Array[String])
      @unreached = T.let(T.unsafe(nil), T::Array[String])
      @class_level = T.let(T.unsafe(nil), T::Array[String])
      @without_op = T.let(T.unsafe(nil), T::Array[String])
      @unmapped = T.let(T.unsafe(nil), T::Array[String])
      @redirected = T.let(T.unsafe(nil), T::Array[String])
      @opaque = T.let(T.unsafe(nil), T::Array[Opaque])
      @code_only = T.let(T.unsafe(nil), T::Array[String])
    end

    sig { params(unit: Inference::Unit).void }
    def observe(unit); end

    sig { returns(T::Boolean) }
    def empty?; end

    sig { params(stamps: T::Array[Stamp], resource: Mapping::Resource).returns(T::Array[String]) }
    def not_observed(stamps, resource); end

    private

    sig { params(unit: Inference::Unit, extracted: Extractor::Extracted).void }
    def observe_extracted(unit, extracted); end

    sig { params(stamps: T::Array[Stamp]).returns(T::Array[String]) }
    def role_universe(stamps); end

    sig { params(resource: Mapping::Resource).returns(T::Array[Dim]) }
    def dims(resource); end

    sig { params(resource: Mapping::Resource).returns(T::Array[Dim]) }
    def tenant_dims(resource); end

    sig { returns(T::Array[String]) }
    def outside_roles; end

    sig { params(dim: Dim, stamps: T::Array[Stamp]).returns(T::Array[T::Array[String]]) }
    def domain(dim, stamps); end

    sig { params(index: Integer, assignment: Assignment, stamps: T::Array[Stamp]).returns(T::Array[Assignment]) }
    def uncovered(index, assignment, stamps); end

    sig { params(dim: Dim, assignment: Assignment).returns(T::Boolean) }
    def implied?(dim, assignment); end

    sig { params(stamp: Stamp, dim: Dim).returns(Value) }
    def value(stamp, dim); end

    sig { params(stamp: Stamp, dim: Dim).returns(T::Array[String]) }
    def role_set(stamp, dim); end

    sig { params(dim: Dim, value: Value).returns(String) }
    def label(dim, value); end
  end
end
