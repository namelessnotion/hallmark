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
  # (`opaque`), whose outcome the checked lower bound assumes denies; so do
  # the checks a controller makes in its own code, under the entry point.
  # `code_only` lists rules read from code that no stamp or unreached route
  # shows. Of the routes no test reached (phase 2 step 3): `routes_unread`
  # are in controllers outside `app/controllers` (gems, engines),
  # `routes_unchecked` call no authorization in the code Hallmark reads, and
  # `routes_unresolved` authorize a record whose class or rule it could not
  # tell. `checks_unread` are entry points whose controller makes a check
  # in its own code that leaves nothing certain. `mismatches` are GraphQL
  # requests whose context named a current tenant other than the
  # controller's (G6). Of list scopes (phase 3 step 7): `lists_unobserved`
  # showed no record and have no scope read from code, so there is nothing
  # to check, and `cross_tenant_lists` are lists that may show another
  # tenant's records on a resource not mapped `lists: :current_tenant`.
  #
  # Of revocation (phase 3 step 9; not `stale`, which is stamps recorded
  # before their resource's facts were mapped): `stale_explained` are allows
  # after a revocation that other access explains, `stale_unjudged` those
  # Hallmark could not judge, `revoked_reads` allows whose freshly read
  # roles still held the revoked role, `unwatched` why the collector watched
  # no membership, `caches_accepted` role reads cached on purpose
  # (`cache_ok`, with the reason) and `role_reads_unread` calls the
  # revocation lint could not follow.
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
                :code_only, :exempt, :routes_unread, :routes_unchecked, :routes_unresolved, :checks_unread, :stale,
                :mismatches, :cross_tenant_lists, :lists_unobserved, :stale_explained, :stale_unjudged,
                :revoked_reads, :unwatched, :caches_accepted, :role_reads_unread

    def initialize(mapping, stamps, mismatches: [])
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
      @stale = []
      @checks_unread = []
      @opaque = []
      @code_only = []
      @mismatches = mismatches.dup
      start_lists
    end

    # Routes no test reached and list scopes, by what they lack.
    def start_lists
      @routes_unread = []
      @routes_unchecked = []
      @routes_unresolved = []
      @cross_tenant_lists = []
      @lists_unobserved = []
      @stale_explained = []
      @stale_unjudged = []
      @revoked_reads = []
      @unwatched = []
      @caches_accepted = []
      @role_reads_unread = []
    end

    def observe(unit)
      extracted = unit.extracted
      if extracted
        observe_extracted(unit, extracted)
        # A rule no stamp shows is listed under `code_only` instead.
        return if extracted.exact? || unit.stamps.empty?
      elsif unit.allows.empty?
        (unit.list? ? @lists_unobserved : @never_allowed) << unit.key
      end
      combinations = not_observed(unit.stamps, @mapping.fetch(unit.resource))
      return if combinations.empty?

      @gaps << Gap.new(rule: unit.key, resource: unit.resource, op: unit.op, allows: unit.allows.size,
                       denies: unit.denies.size, combinations: combinations)
    end

    def empty?
      [@gaps, @never_allowed, @unreached, @class_level, @without_op, @unmapped, @redirected, @opaque,
       @code_only, @exempt, @stale, @routes_unread, @routes_unchecked, @routes_unresolved,
       @checks_unread, @mismatches, @cross_tenant_lists, @lists_unobserved, @stale_explained, @stale_unjudged,
       @revoked_reads, @unwatched, @caches_accepted, @role_reads_unread].all?(&:empty?)
    end

    # What the revocations collector noted beside its marks, and what the
    # revocation lint accepted or could not follow (`role_reads`, nil
    # without an extractor).
    def observe_revocations(stamp_set, role_reads)
      @revoked_reads.concat(stamp_set.revoked_reads.map(&:to_s).uniq.sort)
      @unwatched.concat(stamp_set.unwatched.map(&:to_s).uniq.sort)
      return unless role_reads

      @caches_accepted.concat(role_reads.accepted.map(&:to_s))
      @role_reads_unread.concat(role_reads.unread.map(&:to_s).uniq)
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

    # A serializer field's condition (phase 3 step 8): the calls in it the
    # extractor could not read, under `name` ("EP Serializer#field").
    def observe_field(name, guard) = observe_opaque(name, guard)

    # The checks an entry point's controller makes in its own code: the
    # calls in them the extractor could not read, and the entry point when
    # they leave nothing `certain`.
    def observe_checks(entry_point, guards, certain:)
      guards.each { |guard| observe_opaque(entry_point, guard) }
      @checks_unread << entry_point unless certain || @checks_unread.include?(entry_point)
    end

    private

    def observe_extracted(unit, extracted)
      seen = unit.stamps.any? || (unit.calls || []).any?
      (unit.list? ? @lists_unobserved : @never_allowed) << unit.key if unit.guard.nil? && seen
      observe_opaque(unit.key, extracted.guard)
    end

    def observe_opaque(name, guard)
      guard.opaque_leaves.each do |leaf|
        entry = Opaque.new(rule: name, call: leaf.operands[0], location: leaf.operands[1])
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
