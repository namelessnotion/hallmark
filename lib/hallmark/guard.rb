# frozen_string_literal: true

module Hallmark
  # The condition under which an application allows an exposure, as a small
  # expression tree. Guards compose with `&`, `|` and `~` (not), the same
  # operators DeclarativePolicy uses in its rule DSL.
  #
  # In the phase 0 spike guards are written by hand; phase 2 extracts them
  # from policy code.
  class Guard
    KINDS = %i[none logged_in owner admin role public and or not].freeze

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

    # Alloy formula over the principal `p` and record `r`.
    def to_alloy
      case kind
      when :none then "unguarded"
      when :logged_in then "authenticated[p]"
      when :owner then "r.owner = p"
      when :admin then "isAdmin[p]"
      when :role then "#{Naming.role_sig(operands.first)} in effective[p]"
      when :public then "r in Public"
      when :and then "(#{operands[0].to_alloy} and #{operands[1].to_alloy})"
      when :or then "(#{operands[0].to_alloy} or #{operands[1].to_alloy})"
      when :not then "(not #{operands[0].to_alloy})"
      end
    end

    # Role names this guard mentions, so the model can declare them.
    def roles
      return [operands.first.to_s] if kind == :role
      return [] unless %i[and or not].include?(kind)

      operands.flat_map(&:roles).uniq
    end

    def to_s
      case kind
      when :none then "no check"
      when :logged_in then "logged_in"
      when :owner then "owner"
      when :admin then "admin"
      when :role then "role(:#{operands.first})"
      when :public then "public_record"
      when :and then "(#{operands[0]} & #{operands[1]})"
      when :or then "(#{operands[0]} | #{operands[1]})"
      when :not then "~#{operands[0]}"
      end
    end

    def inspect = "#<Hallmark::Guard #{self}>"

    def ==(other)
      other.is_a?(Guard) && kind == other.kind && operands == other.operands
    end
    alias eql? ==

    def hash = [kind, operands].hash

    private

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
      def role(name) = Guard.new(:role, name.to_s)
      def public_record = Guard.new(:public)
    end
  end
end
