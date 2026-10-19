# typed: strict
# frozen_string_literal: true

module Hallmark
  # What the stamps did not cover: reported beside the findings, never as
  # findings (docs/adr/0002).
  #
  # For each rule, the fact combinations that no stamp allowed or denied are
  # "not observed": between the inferred guard (the OR of the allow-stamps)
  # and everything the rule was never seen to deny. They are listed as
  # conjunctions over the mapped facts, found by splitting the fact space one
  # fact at a time (logged in, public, owner, explicit permission, record
  # outside tenants, record in the current tenant, then the roles held in
  # each place) and stopping wherever no stamp is left, so each line covers
  # a whole unexplored region.
  #
  # Roles are split by the set held, drawn from no role, each single role,
  # and the sets some stamp shows; combinations of several roles that no
  # stamp shows are not listed.
  #
  # `redirected` lists entry points excused from threat 10 by Inference: a
  # GET or HEAD they redirected with no authorization call, while another
  # request to them reached a rule. `exempt` lists entry points that served
  # a request without one where the controller exempts the action from
  # `verify_authorized` (read from code).
  #
  # With the extractor (docs/adr/0003), a rule read exactly from code has no
  # not-observed region, since the code says what it allows everywhere; a
  # rule with opaque leaves keeps its stamp regions and lists each call
  # (`opaque`), whose outcome the checked lower bound assumes denies.
  # `code_only` lists rules read from code that no stamp shows.
  class Coverage
    # One fact a stamp records, as a dimension of the fact space: a boolean,
    # or the set of roles held in one place (`roles` is true).
    Dim = Struct.new(:kind, :label, :roles, keyword_init: true)

    # A rule's not-observed combinations, such as
    # "logged_in & ~in_current_tenant & record_roles=[]".
    Gap = Struct.new(:rule, :resource, :op, :allows, :denies, :combinations, keyword_init: true)

    # A call inside a rule the extractor could not read.
    Opaque = Struct.new(:rule, :call, :location, keyword_init: true) do
      def to_s = "#{rule}: `#{call}`#{" (#{location})" if location}"
    end

    # Facts an anonymous visitor never has.
    ANONYMOUS_LACKS = %i[owner permitted record_roles current_roles roles].freeze

    attr_reader :gaps, :never_allowed, :unreached, :class_level, :without_op, :unmapped, :redirected, :opaque,
                :code_only, :exempt

    def initialize(mapping, stamps)
      @mapping = mapping
      @universe = role_universe(stamps)
      @dims = []
      @domains = {}
      @gaps = []
      @never_allowed = []
      @unreached = []
      @class_level = []
      @without_op = []
      @unmapped = []
      @redirected = []
      @exempt = []
      @opaque = []
      @code_only = []
    end

    def observe(unit)
      extracted = unit.extracted
      if extracted
        observe_extracted(unit, extracted)
        # A rule no stamp shows is listed under `code_only` instead.
        return if extracted.exact? || unit.stamps.empty?
      elsif unit.allows.empty?
        @never_allowed << unit.key
      end
      combinations = not_observed(unit.stamps, @mapping.fetch(unit.resource))
      return if combinations.empty?

      @gaps << Gap.new(rule: unit.key, resource: unit.resource, op: unit.op, allows: unit.allows.size,
                       denies: unit.denies.size, combinations: combinations)
    end

    def empty?
      [@gaps, @never_allowed, @unreached, @class_level, @without_op, @unmapped, @redirected, @opaque,
       @code_only, @exempt].all?(&:empty?)
    end

    # Fact combinations, as conjunctions, that none of `stamps` covers.
    def not_observed(stamps, resource)
      @dims = dims(resource)
      @domains = @dims.select(&:roles).to_h { |dim| [dim, domain(dim, stamps)] }
      # Broadest regions first, otherwise in splitting order.
      regions = uncovered(0, {}, stamps).each_with_index.sort_by { |assignment, index| [assignment.size, index] }
      regions.map do |assignment, _|
        assignment.map { |dim, value| label(dim, value) }.join(" & ")
      end
    end

    private

    def observe_extracted(unit, extracted)
      @never_allowed << unit.key if unit.guard.nil? && unit.stamps.any?
      extracted.opaque_leaves.each do |leaf|
        entry = Opaque.new(rule: unit.key, call: leaf.operands[0], location: leaf.operands[1])
        @opaque << entry unless @opaque.include?(entry)
      end
    end

    # Every role the mapping or any stamp names.
    def role_universe(stamps)
      names = @mapping.grants.map(&:role) + @mapping.platform_roles + [@mapping.tenancy&.self_role].compact
      names += @mapping.rules.values.filter_map(&:guard).flat_map(&:roles)
      names += stamps.flat_map { |stamp| Array(stamp.roles) + Array(stamp.record_roles) + Array(stamp.current_roles) }
      names.map(&:to_s).uniq.sort
    end

    def dims(resource)
      out = [Dim.new(kind: :logged_in, label: "logged_in")]
      out << Dim.new(kind: :public_record, label: "public_record") if resource.public? && !resource.always_public?
      out << Dim.new(kind: :owner, label: "owner") if resource.owned?
      out << Dim.new(kind: :permitted, label: "permitted") if resource.permits?
      out.concat(tenant_dims(resource)) if @mapping.tenancy
      out << Dim.new(kind: :roles, label: "roles", roles: true) if outside_roles.any?
      out
    end

    def tenant_dims(resource)
      out = []
      out << Dim.new(kind: :outside_tenants, label: "outside_tenants") if resource.tenant_optional?
      if resource.tenanted?
        out << Dim.new(kind: :in_current_tenant, label: "in_current_tenant")
        out << Dim.new(kind: :record_roles, label: "record_roles", roles: true)
      end
      out << Dim.new(kind: :current_roles, label: "current_roles", roles: true)
    end

    # Roles held outside tenants: only platform roles in a tenant-aware mapping.
    def outside_roles = @mapping.tenancy ? @mapping.platform_roles.sort : @universe

    # The role sets to split on: none, each single role, and every set seen.
    def domain(dim, stamps)
      roles = dim.kind == :roles ? outside_roles : @universe - @mapping.platform_roles
      ([[]] + roles.map { |name| [name] } + stamps.map { |stamp| role_set(stamp, dim) }).uniq
    end

    # Splits on one dimension at a time; a region with no stamp left is one
    # not-observed combination.
    def uncovered(index, assignment, stamps)
      return [assignment] if stamps.empty?

      dim = @dims[index]
      return [] unless dim
      return uncovered(index + 1, assignment, stamps) if implied?(dim, assignment)

      values = dim.roles ? @domains.fetch(dim) : [true, false]
      values.flat_map do |value|
        uncovered(index + 1, assignment.merge(dim => value), stamps.select { |stamp| value(stamp, dim) == value })
      end
    end

    # Dimensions the earlier ones already decide: an anonymous visitor owns
    # nothing and holds no roles, a record outside tenants is in no tenant
    # to hold roles in, and in the current tenant the current tenant's roles
    # are the record tenant's.
    def implied?(dim, assignment)
      held = assignment.to_h { |other, value| [other.kind, value] }
      return true if held[:logged_in] == false && ANONYMOUS_LACKS.include?(dim.kind)
      return true if held[:outside_tenants] == true && %i[in_current_tenant record_roles].include?(dim.kind)

      dim.kind == :current_roles && held[:in_current_tenant] == true
    end

    def value(stamp, dim)
      return role_set(stamp, dim) if dim.roles

      stamp[dim.kind] == true
    end

    def role_set(stamp, dim) = Array(stamp[dim.kind]).map(&:to_s).sort

    def label(dim, value)
      return "#{dim.label}=[#{value.join(", ")}]" if value.is_a?(Array)

      value ? dim.label : "~#{dim.label}"
    end
  end
end
