# typed: strict
# frozen_string_literal: true

require "digest"

module Hallmark
  # The GraphQL reachability model (phase 3 step 5; research/models/graphql.als
  # in the shipped catalog's terms), built from a schema read from source
  # (`Extractor::GraphqlSchema`) and a mapping.
  #
  # A type backing a mapped resource is modeled by that resource's
  # signature, and a field between two of them by a relation on the
  # parent's (`gql_Organization_projects`). A path through types that back
  # no resource collapses into one edge (`gql_Project_billing_invoices`):
  # kept when nothing on the way checks anything, left out (and listed)
  # when something does, since a finding must never rest on a check
  # Hallmark did not model. Every guard is checked by its lower bound
  # (docs/adr/0003), so what the model calls reachable certainly is.
  #
  # A viewer reaches the objects root fields return (any record of the
  # type, whatever the arguments) whose checks pass, then follows fields
  # whose check on the parent passes and whose returned object passes its
  # own: the field's checks on what it returns, the type's `scope_items`
  # on list members, and the type's `authorized?` (unless
  # `reauthorize_scoped_objects(false)` and the scope ran). Mutations are
  # not entry points here: they write, and the G4 lint checks them.
  class GraphqlModel
    # Types that back no resource a collapsed edge may pass through.
    MAX_UNMAPPED = 2

    # Collapsed and unmodeled edges listed in the report; the rest counted.
    SHOWN = 12

    # Guard leaves that read the checked record.
    RECORD_KINDS = %i[owner public in_current_tenant outside_tenants permitted flag].freeze

    # One field followed to one of the types it returns.
    Step = Struct.new(:field, :target, keyword_init: true)

    # A root entry (parent nil) or an edge between mapped types: the steps
    # from the parent (or the root type) to the child, the check on the
    # parent, the checks on the child (`entry`), the types backing no
    # resource it passes, and the checks on those Hallmark cannot model
    # (`unread`), which keep it out of the model. `relation` names it in
    # Alloy (edges only).
    Edge = Struct.new(:parent, :steps, :child, :guard, :entry, :through, :unread, :relation, keyword_init: true) do
      def path = steps.map { |step| step.field.graphql_name }.join(".")
      def collapsed? = !through.empty?
    end

    attr_reader :schema, :roots, :edges, :unmodeled, :types, :cut

    def initialize(mapping, schema)
      @mapping = mapping
      @schema = schema
      @roots = []
      @edges = []
      @unmodeled = []
      @types = []
      @cut = 0
      @checks = nil
      build
      @alloy = Alloy.new(self, mapping)
    end

    def lints = @schema.lints

    # One check per mapped type reached, and one per field of it with a
    # field policy.
    def checks = @checks ||= @types.flat_map { |name| [type_check(name), *field_checks(name)] }

    # The resources the model needs signatures for.
    def resources = @types.filter_map { |name| @schema.type(name).resource }.uniq

    # The relations declared on a resource's signature, as Alloy fields.
    def relations_of(resource)
      @edges.select { |edge| @schema.type(edge.parent.to_s).resource == resource }.map do |edge|
        "#{edge.relation}: set #{signature(edge.child)}"
      end
    end

    # Every guard the model renders, with the resource it is checked on,
    # for validation and for declaring roles.
    def guards
      found = (@roots + @edges).flat_map do |edge|
        parent = edge.parent
        on_parent = parent ? [[edge.guard.lower, @schema.type(parent).resource.to_s]] : []
        on_parent + [[edge.entry.lower, @schema.type(edge.child).resource.to_s]]
      end
      found + checks.select(&:field).map { |check| [check.guard, check.resource] }
    end

    # The Alloy shared by every check (`Alloy#source`).
    def source(tenancy) = @alloy.source(tenancy)

    # A digest of the shared Alloy, for `GraphqlCheck#digest`.
    def fingerprint(mapping) = Digest::SHA256.hexdigest(source(!mapping.tenancy.nil?))

    def quantifier(check, tenancy) = @alloy.quantifier(check, tenancy)
    def field_read(check, tenancy) = @alloy.field_read(check, tenancy)

    # The query a client would send to reach the witness (`Witness`).
    def path(check, instance) = Witness.new(self, instance).path(check)

    # The Alloy signature of the resource a type backs.
    def signature(type_name) = @mapping.fetch(@schema.type(type_name).resource.to_s).alloy_sig

    # "Query.organization", "Project.billing.invoices"
    def way(edge)
      parent = edge.parent
      prefix = parent ? @schema.type(parent).graphql_name : "Query"
      "#{prefix}.#{edge.path}"
    end

    # Coverage notes for the report: collapsed edges kept, edges left out
    # and why, and the checks on mapped types Hallmark could not read.
    def notes
      collapsed = (@roots + @edges).select { |edge| edge.collapsed? && edge.unread.empty? }
      {
        "GraphQL fields through types that back no mapped resource, modeled as one edge" =>
          collapsed.map { |edge| describe(edge) },
        "GraphQL fields not modeled (a check on the way could not be read; the model assumes it denies)" =>
          @unmodeled.map { |edge| "#{describe(edge)}: #{edge.unread.uniq.join("; ")}" },
        "GraphQL checks Hallmark could not read (the checked guard assumes each one denies)" => opaque_checks
      }
    end

    private

    def build
      query = @schema.root(:query)
      return unless query

      @roots = walk(nil, @schema.fields(query))
      queue = @roots.select { |edge| edge.unread.empty? }.map(&:child).uniq
      seen = []
      while (name = queue.shift)
        next if seen.include?(name)

        seen << name
        found = walk(name, @schema.fields(name))
        @edges.concat(found)
        queue.concat(found.select { |edge| edge.unread.empty? }.map(&:child))
      end
      settle
    end

    # Keeps what the model can use, names relations, and records the
    # mapped types reached.
    def settle
      @unmodeled = (@roots + @edges).reject { |edge| edge.unread.empty? }
      @roots = distinct_roots
      @edges = @edges.select { |edge| edge.unread.empty? }
      name_relations
      @types = (@roots.map(&:child) + @edges.map(&:child)).uniq.sort
    end

    # `node` and `nodes` (or two root fields with the same checks) enter
    # the same way: one predicate each is enough, the shortest path's.
    def distinct_roots
      kept = @roots.select { |edge| edge.unread.empty? }.each_with_index.sort_by { |edge, at| [edge.steps.size, at] }
      kept.map(&:first).uniq { |edge| [edge.child, edge.entry.lower.to_s] }
    end

    def name_relations
      names = []
      @edges.each do |edge|
        edge.relation = unique(relation_name(edge), names)
        names << edge.relation
      end
    end

    def unique(name, taken)
      return name unless taken.include?(name)

      (2..).lazy.map { |index| "#{name}_#{index}" }.find { |candidate| !taken.include?(candidate) }.to_s
    end

    def relation_name(edge)
      parent = @schema.type(edge.parent.to_s).graphql_name
      fields = edge.steps.map { |step| step.field.graphql_name }
      ambiguous = edge.steps.any? { |step| step.field.targets.size > 1 }
      fields << @schema.type(edge.child).graphql_name if ambiguous
      Naming.identifier("gql_#{parent}_#{fields.join("_")}")
    end

    def walk(parent, fields)
      fields.flat_map do |field|
        field.targets.flat_map { |target| descend(parent, [Step.new(field: field, target: target)], [], []) }
      end
    end

    # Follows steps until a mapped type, through at most MAX_UNMAPPED
    # types that back no resource, collecting the checks made on those.
    def descend(parent, steps, through, unread)
      last = steps.last || raise(ArgumentError, "a path needs a step")
      target = last.target
      type = @schema.type(target)
      return [edge(parent, steps, through, unread)] if type.resource

      if through.size >= MAX_UNMAPPED || through.include?(target)
        @cut += 1
        return []
      end

      here = unread + checks_on(type, last.field)
      @schema.fields(target).flat_map do |field|
        more = field.guard.kind == :none ? here : here + ["#{target}##{field.name}: #{field.guard}"]
        field.targets.flat_map do |next_target|
          descend(parent, steps + [Step.new(field: field, target: next_target)], through + [target], more)
        end
      end
    end

    # The checks a type backing no resource makes, which Hallmark cannot
    # model since no signature stands for its objects.
    def checks_on(type, field)
      found = []
      found << "#{type.name}.authorized?: #{type.guard}" unless type.guard.kind == :none
      found << "#{type.name}.scope_items" if type.scope && field.scoped?
      child = @schema.child_guard(field, type.name)
      found << "#{field.key} on what it returns: #{child}" unless child.kind == :none
      found
    end

    def edge(parent, steps, through, unread)
      first = steps.first || raise(ArgumentError, "a path needs a step")
      last = steps.last || raise(ArgumentError, "a path needs a step")
      guard = first.field.guard
      entry = entry_guard(last.field, last.target)
      unread += bound_reasons(parent, first.field, guard, entry, last.target)
      Edge.new(parent: parent, steps: steps, child: last.target, guard: parent ? guard : Guard.new(:none),
               entry: parent ? entry : Guard.conjoin(guard, entry), through: through, unread: unread)
    end

    # Why an edge leaves the model: a check whose lower bound allows
    # nothing, or a root field's check that reads the record (it runs on
    # the query's root object, not on what the field returns).
    def bound_reasons(parent, field, guard, entry, child)
      reasons = []
      if parent.nil? && reads_record?(guard)
        reasons << "#{field.key}: its check on the root object reads a record (#{guard})"
      elsif guard.lower.kind == :never
        reasons << "#{field.key}: #{guard}"
      end
      reasons << "#{child} on arrival: #{entry}" if entry.lower.kind == :never
      reasons
    end

    def reads_record?(guard)
      guard.leaves.any? do |leaf|
        RECORD_KINDS.include?(leaf.kind) || (leaf.kind == :role && leaf.operands[1] == :record)
      end
    end

    # What an object a field returns must pass: the field's checks on it,
    # its type's `scope_items` when the field is scoped, and its type's
    # `authorized?` (skipped after a scope under
    # `reauthorize_scoped_objects(false)`).
    def entry_guard(field, target)
      type = @schema.type(target)
      guard = @schema.child_guard(field, target)
      scope = type.scope
      scoped = !scope.nil? && field.scoped?
      guard = Guard.conjoin(guard, scope) if scope && scoped
      scoped && !type.reauthorize ? guard : Guard.conjoin(guard, type.guard)
    end

    def type_check(name)
      type = @schema.type(name)
      resource = type.resource.to_s
      ways = (@roots + @edges).select { |edge| edge.child == name }.map { |edge| way(edge) }.uniq
      basis = "type check #{guard_origin(type)}; reached through #{ways.first(3).join(", ")}"
      GraphqlCheck.new(type: name, graphql_name: type.graphql_name, resource: resource, field: nil,
                       field_graphql_name: nil, guard: type.guard.lower, basis: basis,
                       locations: Array(type.location), rules: ["#{name}#authorized?"], graph: self)
    end

    def guard_origin(type)
      where = type.location ? " (#{type.location})" : ""
      return "none in #{type.name}#{where}" if type.guard.kind == :none

      bounded = type.guard.opaque? ? ", lower bound" : ""
      "read from #{type.name}#{where}#{bounded}"
    end

    def field_checks(name)
      type = @schema.type(name)
      resource = type.resource.to_s
      @schema.fields(name).filter_map do |field|
        policy = @mapping.field_policy_for(resource, field.name) ||
                 @mapping.field_policy_for(resource, field.graphql_name)
        next unless policy
        next if field.guard.lower.kind == :never

        GraphqlCheck.new(type: name, graphql_name: type.graphql_name, resource: resource, field: policy.field,
                         field_graphql_name: field.graphql_name, guard: field.guard.lower,
                         basis: "field check #{field_origin(field)}", locations: Array(field.location),
                         rules: ["#{name}#authorized?"], graph: self)
      end
    end

    def field_origin(field)
      return "none on #{field.key} (#{field.location})" if field.guard.kind == :none

      "read from #{field.key} (#{field.location}#{", lower bound" if field.guard.opaque?})"
    end

    def describe(edge)
      through = edge.through.map { |name| @schema.type(name).graphql_name }
      "#{way(edge)}#{" (through #{through.join(", ")})" unless through.empty?}"
    end

    def opaque_checks
      found = @types.flat_map do |name|
        type = @schema.type(name)
        leaves = type.guard.opaque_leaves.map { |leaf| [type.name, leaf] }
        leaves + @schema.fields(name).flat_map { |field| field.guard.opaque_leaves.map { |leaf| [field.key, leaf] } }
      end
      found.map { |owner, leaf| "#{owner}: `#{leaf.operands[0]}`#{" (#{leaf.operands[1]})" if leaf.operands[1]}" }.uniq
    end
  end
end

require_relative "graphql_model/alloy"
require_relative "graphql_model/witness"
