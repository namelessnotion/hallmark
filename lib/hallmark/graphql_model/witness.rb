# typed: strict
# frozen_string_literal: true

module Hallmark
  class GraphqlModel
    # The query a client would send to reach a GraphQL check's witness,
    # rebuilt in Ruby from the instance's relation tuples (no solver
    # `eval`, so both backends explain it): breadth first from the root
    # object `o` to `r`, over modeled steps whose checks the witness does
    # not fail as far as it says (three-valued, as `WitnessFacts`), else
    # over any step. Printed in GraphQL names, arguments elided:
    # `query { node(id: ...) { ... on Project { billing { invoices { ... } } } } }`.
    class Witness
      def initialize(model, instance)
        @model = model
        @instance = instance
      end

      def path(check)
        name = check.check_name
        atoms = %w[p cur o r].to_h { |key| [key, @instance.skolem("$#{name}_#{key}")] }
        steps = search(check, atoms, strict: true) || search(check, atoms, strict: false)
        return nil unless steps

        render(steps, check.field ? check.field_graphql_name.to_s : "...")
      end

      private

      def search(check, atoms, strict:)
        start = atoms["o"]
        target = atoms["r"]
        return nil unless start && target

        facts = facts_for(atoms) if strict
        breadth_first(entries(start, facts).map { |edge| [start, edge.child, edge.steps] }, [target, check.type], facts)
      end

      # The steps of the first state at `goal` (an atom and its type).
      def breadth_first(queue, goal, facts)
        seen = []
        while (state = queue.shift)
          atom, type, steps = state
          return steps if [atom, type] == goal
          next if seen.include?([atom, type])

          seen << [atom, type]
          queue.concat(next_states(atom, type, steps, facts))
        end
        nil
      end

      def facts_for(atoms) = ->(atom) { Facts.new(@instance, atoms["p"].to_s, atoms["cur"], atom) }

      # The root entries the root object fits and passes.
      def entries(start, facts)
        @model.roots.select { |edge| fits?(edge.child, start) && passes?(edge.entry, start, facts) }
      end

      def passes?(guard, atom, facts) = facts.nil? || guard.lower.evaluate(facts.call(atom)) != false

      def next_states(atom, type, steps, facts)
        @model.edges.select { |edge| edge.parent == type && passes?(edge.guard, atom, facts) }.flat_map do |edge|
          @instance.field(atom, edge.relation.to_s).filter_map do |child|
            [child, edge.child, steps + edge.steps] if passes?(edge.entry, child, facts)
          end
        end
      end

      def fits?(type, atom) = Naming.atom(atom).sub(/\$\d+\z/, "") == @model.signature(type)

      def render(steps, leaf)
        inner = "{ #{leaf} }"
        steps.reverse_each do |step|
          field = step.field
          selection = inner
          selection = "{ ... on #{@model.schema.type(step.target).graphql_name} #{selection} }" if field.via
          selection = "{ nodes #{selection} }" if field.connection
          arguments = field.arguments.map { |name| "#{name}: ..." }.join(", ")
          inner = "{ #{field.graphql_name}#{"(#{arguments})" unless arguments.empty?} #{selection} }"
        end
        "query #{inner}"
      end
    end

    # What a witness says about each guard leaf on one atom, as
    # `WitnessFacts` does for the finding's record: true, false or nil
    # (unknown: public records, permits).
    class Facts
      def initialize(instance, principal, current, atom)
        @instance = instance
        @principal = principal
        @current = current
        @atom = atom
      end

      def [](leaf)
        case leaf.kind
        when :logged_in then !Naming.atom(@principal).start_with?("Anonymous")
        when :owner then @instance.field(@atom, "owner").first == @principal
        when :admin then assigned.include?("Admin")
        when :role then role?(leaf.operands[0].to_s, leaf.operands[1])
        when :in_current_tenant then @current.nil? ? nil : tenant == @current
        when :outside_tenants then tenant.nil?
        when :flag then @instance.sources(Naming.flag_field(leaf.operands[0].to_s), @atom).any?
        end
      end

      private

      def tenant = @instance.field(@atom, "tenant").first

      def assigned = @instance.field(@principal, "assigned").map { |role| Finding.role_name(role) }

      def role?(name, where)
        return assigned.include?(name) if where.nil?

        memberships = @instance.sources("member", @principal)
        unless where == :any
          memberships = memberships.select { |membership| @instance.field(membership, "within").include?(scope(where)) }
        end
        memberships.any? do |membership|
          @instance.field(membership, "roles").map { |role| Finding.role_name(role) }.include?(name)
        end
      end

      def scope(where) = where == :current ? @current : tenant
    end
  end
end
