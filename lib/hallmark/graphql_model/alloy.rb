# typed: strict
# frozen_string_literal: true

module Hallmark
  class GraphqlModel
    # The Alloy every GraphQL check shares: each check on an edge as a
    # predicate over `r`, so a guard renders unchanged whichever object it
    # checks; root entries and steps per type (`gqlRoots_<Type>`,
    # `gqlInto_<Type>`); a child in its parent's tenant; and the objects
    # of each type reachable from a root object `o` (`gqlReach_<Type>`).
    # `ModelBuilder` renders the checks themselves.
    class Alloy
      def initialize(model, mapping)
        @model = model
        @mapping = mapping
        @source = {}
      end

      def source(tenancy)
        @source[tenancy] ||= [header, *root_preds(tenancy), *edge_preds(tenancy), *field_preds(tenancy),
                              *tenant_facts(tenancy), *funs(tenancy)].join("\n")
      end

      # A check's quantifier: `p`, `cur` (tenant-aware), the root object
      # `o`, then `r`, the skolems `Finding` and `Witness` read.
      def quantifier(check, tenancy)
        name = Naming.identifier(check.graphql_name)
        if tenancy
          "p: Principal, cur: Tenant, o: gqlRoots[p, cur], r: gqlReach_#{name}[p, cur, o]"
        else
          "p: Principal, o: gqlRoots[p], r: gqlReach_#{name}[p, o]"
        end
      end

      # The predicate a field check reads the field's own check with.
      def field_read(check, tenancy) = "gqlRead_#{check.name_suffix}[#{tenancy ? "p, cur, r" : "p, r"}]"

      private

      def header
        model = @model
        "-- GraphQL: #{model.schema.schema || "a schema"} read from app/graphql; #{model.types.size} mapped types, " \
          "#{model.roots.size} root entries, #{model.edges.size} edges"
      end

      def params(tenancy, variable, type)
        tenancy ? "p: Principal, cur: Tenant, #{variable}: #{type}" : "p: Principal, #{variable}: #{type}"
      end

      def args(tenancy, variable) = tenancy ? "p, cur, #{variable}" : "p, #{variable}"

      def pred(name, tenancy, type, guard) = "pred #{name}[#{params(tenancy, "r", type)}] { #{guard.to_alloy("Read")} }"

      def graphql_name(type) = @model.schema.type(type).graphql_name

      def root_preds(tenancy)
        @model.roots.each_with_index.flat_map do |edge, index|
          ["-- Query.#{edge.path}: #{graphql_name(edge.child)}, entry: #{edge.entry.lower}",
           pred("gqlRoot_#{index}", tenancy, @model.signature(edge.child), edge.entry.lower)]
        end
      end

      def edge_preds(tenancy)
        @model.edges.flat_map do |edge|
          ["-- #{@model.way(edge)}: #{graphql_name(edge.child)}, on the parent: #{edge.guard.lower}, " \
           "entry: #{edge.entry.lower}",
           pred("gqlOn_#{edge.relation}", tenancy, @model.signature(edge.parent.to_s), edge.guard.lower),
           pred("gqlIn_#{edge.relation}", tenancy, @model.signature(edge.child), edge.entry.lower)]
        end
      end

      def field_preds(tenancy)
        @model.checks.select(&:field).map do |check|
          pred("gqlRead_#{check.name_suffix}", tenancy, @model.signature(check.type), check.guard)
        end
      end

      # A child lives in its parent's tenant, unless its type
      # `crosses_tenants:` or either resource may live outside tenants.
      def tenant_facts(tenancy)
        return [] unless tenancy

        @model.edges.filter_map do |edge|
          parent = resource(edge.parent.to_s)
          next if @mapping.graphql_types[edge.child]&.crosses_tenants || !same_tenant?(parent, resource(edge.child))

          relation = edge.relation
          "fact #{relation}_same_tenant { all a: #{parent.alloy_sig}, b: a.#{relation} | b.tenant = a.tenant }"
        end
      end

      def resource(type) = @mapping.fetch(@model.schema.type(type).resource.to_s)

      def same_tenant?(parent, child)
        [parent, child].all? { |resource| resource.tenanted? && !resource.tenant_optional? }
      end

      def funs(tenancy)
        own = tenancy ? "p: Principal, cur: Tenant" : "p: Principal"
        call = tenancy ? "p, cur" : "p"
        types = @model.types
        lines = types.flat_map { |name| type_funs(name, own, tenancy) }
        steps = types.map { |name| "gqlInto_#{id(name)}[#{call}]" }
        roots = types.map { |name| "gqlRoots_#{id(name)}[#{call}]" }
        lines << "fun gqlStep[#{own}]: Resource -> Resource { #{union(steps, "none -> none")} }"
        lines << "fun gqlRoots[#{own}]: set Resource { #{union(roots, "none")} }"
        lines + types.map do |name|
          "fun gqlReach_#{id(name)}[#{own}, o: Resource]: set #{@model.signature(name)} " \
            "{ (o & gqlRoots_#{id(name)}[#{call}]) + o.*(gqlStep[#{call}]).(gqlInto_#{id(name)}[#{call}]) }"
        end
      end

      def type_funs(name, own, tenancy)
        target = @model.signature(name)
        roots = @model.roots.each_index.select { |index| @model.roots.fetch(index).child == name }.map do |index|
          "{ r: #{target} | gqlRoot_#{index}[#{args(tenancy, "r")}] }"
        end
        into = @model.edges.select { |edge| edge.child == name }.map do |edge|
          "{ a: #{@model.signature(edge.parent.to_s)}, b: #{target} | b in a.#{edge.relation} and " \
            "gqlOn_#{edge.relation}[#{args(tenancy, "a")}] and gqlIn_#{edge.relation}[#{args(tenancy, "b")}] }"
        end
        ["fun gqlRoots_#{id(name)}[#{own}]: set #{target} { #{union(roots, "none")} }",
         "fun gqlInto_#{id(name)}[#{own}]: Resource -> #{target} { #{union(into, "none -> none")} }"]
      end

      def union(parts, empty) = parts.empty? ? empty : parts.join(" + ")

      def id(name) = Naming.identifier(graphql_name(name))
    end
  end
end
