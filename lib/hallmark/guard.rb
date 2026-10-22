# typed: strict
# frozen_string_literal: true

module Hallmark
  # The condition under which an application allows an exposure, as a small
  # expression tree. Guards compose with `&`, `|` and `~` (not), the same
  # operators DeclarativePolicy uses in its rule DSL.
  #
  # Guards are written by hand, inferred from stamps, or extracted from
  # policy code (`Hallmark::Extractor`). An extracted guard may hold opaque
  # leaves, calls the extractor could not read; those never reach Alloy, so
  # such a guard is checked through `#bounds` (docs/adr/0003).
  #
  # Guards over tenants read the current tenant `cur` and the record's tenant
  # `r.tenant`; see `Guard::DSL#role`, `#member`, `#in_current_tenant` and
  # `#outside_tenants`.
  class Guard
    KINDS = %i[none never logged_in owner admin role member public in_current_tenant outside_tenants permitted flag
               opaque and or not].freeze

    # Where a role check looks: outside any tenant (nil), in the current
    # tenant, in the record's tenant, or in any tenant at all.
    ROLE_TENANTS = [nil, :current, :record, :any].freeze

    attr_reader :kind, :operands

    def initialize(kind, *operands)
      raise ArgumentError, "unknown guard kind: #{kind}" unless KINDS.include?(kind)

      @kind = kind
      @operands = operands.freeze
      freeze
    end

    def &(other) = Guard.new(:and, self, coerce(other))
    def |(other) = Guard.new(:or, self, coerce(other))
    def ~ = Guard.new(:not, self)

    # Alloy formula over the principal `p`, record `r` and current tenant
    # `cur`. `op` is the exposure's op ("Read" or "Write"), which `permitted`
    # needs.
    def to_alloy(op = nil)
      case kind
      when :none then "unguarded"
      when :never then "(not unguarded)"
      when :logged_in then "authenticated[p]"
      when :owner then "r.owner = p"
      when :admin then "isAdmin[p]"
      when :role then "#{Naming.role_sig(operands[0])} in #{role_set(operands[1])}"
      when :member then "(some rolesIn[p, r.tenant])"
      when :public then "r in Public"
      when :in_current_tenant then "r.tenant = cur"
      when :outside_tenants then "no r.tenant"
      when :permitted then "permitted[p, #{op || raise(ArgumentError, "permitted needs the exposure's op")}, r]"
      when :flag then "r in #{Naming.flag_sig(operands[0])}"
      when :opaque then raise ArgumentError, "the opaque call #{operands[0]} cannot be modeled; check a bound instead"
      when :and, :or then "(#{operands[0].to_alloy(op)} #{kind} #{operands[1].to_alloy(op)})"
      when :not then "(not #{operands[0].to_alloy(op)})"
      else raise ArgumentError, "unknown guard kind: #{kind}"
      end
    end

    # The conditions this guard combines, left to right.
    def leaves
      %i[and or not].include?(kind) ? operands.flat_map(&:leaves) : [self]
    end

    # Role names this guard mentions, so the model can declare them.
    def roles
      leaves.select { |leaf| leaf.kind == :role }.map { |leaf| leaf.operands[0].to_s }.uniq
    end

    # The tenant terms this guard reads (:current, :record, :any), so an
    # analysis can reject them when the map block declares no tenant.
    def tenants
      leaves.flat_map do |leaf|
        case leaf.kind
        when :role then [leaf.operands[1]].compact
        when :in_current_tenant then [:current]
        when :member, :outside_tenants then [:record]
        else []
        end
      end.uniq
    end

    # The record flags this guard reads.
    def flags = leaves.select { |leaf| leaf.kind == :flag }.map { |leaf| leaf.operands[0].to_s }.uniq

    # Whether this guard reads explicit permissions, which only a resource
    # mapped with `permits:` has.
    def permits? = leaves.any? { |leaf| leaf.kind == :permitted }

    # Whether this guard asks if the record lives outside tenants, which only
    # a resource mapped with `tenant_optional:` can.
    def outside_tenants? = leaves.any? { |leaf| leaf.kind == :outside_tenants }

    # Role checks held outside any tenant: "Admin" for `admin`, else the role name.
    def roles_outside_tenants
      leaves.filter_map do |leaf|
        next "Admin" if leaf.kind == :admin

        leaf.operands[0].to_s if leaf.kind == :role && leaf.operands[1].nil?
      end.uniq
    end

    def to_s
      case kind
      when :none then "no check"
      when :never then "never"
      when :logged_in then "logged_in"
      when :owner then "owner"
      when :admin then "admin"
      when :role then operands[1] ? "role(:#{operands[0]}, tenant: :#{operands[1]})" : "role(:#{operands[0]})"
      when :member then "member"
      when :public then "public_record"
      when :in_current_tenant then "in_current_tenant"
      when :outside_tenants then "outside_tenants"
      when :permitted then "permitted"
      when :flag then "flag(:#{operands[0]})"
      when :opaque then "opaque(`#{operands[0]}`)"
      when :and then "(#{operands[0]} & #{operands[1]})"
      when :or then "(#{operands[0]} | #{operands[1]})"
      when :not then "~#{operands[0]}"
      else raise ArgumentError, "unknown guard kind: #{kind}"
      end
    end

    def inspect = "#<Hallmark::Guard #{self}>"

    # Whether any leaf is a call the extractor could not read.
    def opaque? = leaves.any? { |leaf| leaf.kind == :opaque }

    # The opaque leaves, each once, left to right.
    def opaque_leaves = leaves.select { |leaf| leaf.kind == :opaque }.uniq

    # Opaque-free guards around this one (docs/adr/0003): the lower bound
    # holds only where this guard holds whatever the opaque calls return
    # (each opaque leaf false where it allows, true where it is negated), the
    # upper bound wherever some outcome of them would let it hold. Constants
    # are folded away, so a bound may be `none` or `never`.
    def bounds = [bound(true), bound(false)]

    def lower = bound(true)
    def upper = bound(false)

    # Whether this guard holds where `facts` says what each leaf is (a
    # `StampFacts`, or a Hash from leaf to true or false): true, false or
    # nil, unknown. Three-valued: an opaque leaf, or one `facts` cannot
    # answer, is unknown, `and` is false when either side is, `or` is true
    # when either side is, and anything else touching an unknown is unknown.
    def evaluate(facts)
      case kind
      when :none then true
      when :never then false
      when :opaque then nil
      when :and then both(operands[0].evaluate(facts), operands[1].evaluate(facts))
      when :or then either(operands[0].evaluate(facts), operands[1].evaluate(facts))
      when :not
        value = operands[0].evaluate(facts)
        value.nil? ? nil : !value
      else facts[self]
      end
    end

    def ==(other)
      other.is_a?(Guard) && kind == other.kind && operands == other.operands
    end
    alias eql? ==

    def hash = [kind, operands].hash

    # `&`, `|` and `~` with `none` (true) and `never` (false) folded away.
    def self.conjoin(left, right)
      return right if left.kind == :none
      return left if right.kind == :none
      return left if left.kind == :never
      return right if right.kind == :never

      left & right
    end

    def self.disjoin(left, right)
      return left if left.kind == :none || right.kind == :never
      return right if right.kind == :none || left.kind == :never

      left | right
    end

    def self.negate(guard)
      case guard.kind
      when :none then new(:never)
      when :never then new(:none)
      when :not then guard.operands[0]
      else ~guard
      end
    end

    protected

    # `lower` is true for the lower bound; a negation swaps the two.
    def bound(lower)
      case kind
      when :opaque then Guard.new(lower ? :never : :none)
      when :and then Guard.conjoin(operands[0].bound(lower), operands[1].bound(lower))
      when :or then Guard.disjoin(operands[0].bound(lower), operands[1].bound(lower))
      when :not then Guard.negate(operands[0].bound(!lower))
      else self
      end
    end

    private

    def both(left, right)
      return false if left == false || right == false

      left && right ? true : nil
    end

    def either(left, right)
      return true if left || right

      left == false && right == false ? false : nil
    end

    def role_set(tenant)
      case tenant
      when nil then "effective[p]"
      when :current then "rolesIn[p, cur]"
      when :record then "rolesIn[p, r.tenant]"
      when :any then "rolesAnywhere[p]"
      else raise ArgumentError, "unknown role tenant: #{tenant.inspect}"
      end
    end

    def coerce(other)
      return other if other.is_a?(Guard)

      raise ArgumentError, "cannot combine a guard with #{other.inspect}"
    end

    # Helpers available inside `Hallmark.analyze` blocks.
    module DSL
      def none = Guard.new(:none)
      def logged_in = Guard.new(:logged_in)
      def owner = Guard.new(:owner)
      def admin = Guard.new(:admin)
      def public_record = Guard.new(:public)

      # A role check. `tenant:` says where the role must be held: nil (the
      # default) outside any tenant, :current in the current tenant, :record
      # in the record's tenant, :any in some tenant (an unscoped check such as
      # `user.memberships.exists?(role: :admin)`).
      def role(name, tenant: nil)
        unless ROLE_TENANTS.include?(tenant)
          Kernel.raise ArgumentError, "role tenant must be one of :current, :record or :any, not #{tenant.inspect}"
        end

        Guard.new(:role, name.to_s, tenant)
      end

      # The user holds some role, of any kind, in the record's tenant: a list
      # scope over the user's tenants (`where(organization:
      # user.organizations)`). False for a record outside tenants.
      def member = Guard.new(:member)

      # The record belongs to the current tenant (Gumroad: `record.user == seller`).
      def in_current_tenant = Guard.new(:in_current_tenant)

      # The record lives in no tenant, as a resource mapped with
      # `tenant_optional:` may (a personal article, outside any organization).
      def outside_tenants = Guard.new(:outside_tenants)

      # The user holds an explicit permission on the record for the
      # exposure's op (Gumroad: `user.collaborator_for?(record)`).
      def permitted = Guard.new(:permitted)

      # A named boolean attribute of the record that the mapping declares
      # (`resource ..., flags: %i[public_builds]`), such as a setting of the
      # project a pipeline schedule lives in.
      def flag(name) = Guard.new(:flag, name.to_s)
    end
  end
end
