# typed: strict
# frozen_string_literal: true

module Hallmark
  # The condition under which an application allows an exposure, as a small
  # expression tree. Guards compose with `&`, `|` and `~` (not), the same
  # operators DeclarativePolicy uses in its rule DSL.
  #
  # In the phase 0 spike guards are written by hand; phase 2 extracts them
  # from policy code.
  #
  # Guards over tenants read the current tenant `cur` and the record's tenant
  # `r.tenant`; see `Guard::DSL#role` and `#in_current_tenant`.
  class Guard
    KINDS = %i[none logged_in owner admin role public in_current_tenant permitted and or not].freeze

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
      when :logged_in then "authenticated[p]"
      when :owner then "r.owner = p"
      when :admin then "isAdmin[p]"
      when :role then "#{Naming.role_sig(operands[0])} in #{role_set(operands[1])}"
      when :public then "r in Public"
      when :in_current_tenant then "r.tenant = cur"
      when :permitted then "permitted[p, #{op || raise(ArgumentError, "permitted needs the exposure's op")}, r]"
      when :and then "(#{operands[0].to_alloy(op)} and #{operands[1].to_alloy(op)})"
      when :or then "(#{operands[0].to_alloy(op)} or #{operands[1].to_alloy(op)})"
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
        else []
        end
      end.uniq
    end

    # Whether this guard reads explicit permissions, which only a resource
    # mapped with `permits:` has.
    def permits? = leaves.any? { |leaf| leaf.kind == :permitted }

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
      when :logged_in then "logged_in"
      when :owner then "owner"
      when :admin then "admin"
      when :role then operands[1] ? "role(:#{operands[0]}, tenant: :#{operands[1]})" : "role(:#{operands[0]})"
      when :public then "public_record"
      when :in_current_tenant then "in_current_tenant"
      when :permitted then "permitted"
      when :and then "(#{operands[0]} & #{operands[1]})"
      when :or then "(#{operands[0]} | #{operands[1]})"
      when :not then "~#{operands[0]}"
      else raise ArgumentError, "unknown guard kind: #{kind}"
      end
    end

    def inspect = "#<Hallmark::Guard #{self}>"

    def ==(other)
      other.is_a?(Guard) && kind == other.kind && operands == other.operands
    end
    alias eql? ==

    def hash = [kind, operands].hash

    private

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

      # The record belongs to the current tenant (Gumroad: `record.user == seller`).
      def in_current_tenant = Guard.new(:in_current_tenant)

      # The user holds an explicit permission on the record for the
      # exposure's op (Gumroad: `user.collaborator_for?(record)`).
      def permitted = Guard.new(:permitted)
    end
  end
end
