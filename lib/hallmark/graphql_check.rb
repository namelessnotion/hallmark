# typed: strict
# frozen_string_literal: true

require "digest"
require "json"

module Hallmark
  # One check of the GraphQL reachability model (phase 3 step 5), beside
  # the entry-point exposures: every object of a mapped type a viewer can
  # reach from the schema's root fields and `node(id:)` must be readable by
  # the catalog (`reach_<Type>`), and a field with a `field_policy` must not
  # be readable where its policy says no (`reach_<Type>_<field>`).
  #
  # It answers what `Report`, `Finding`, `Sarif`, `Baseline` and `Watch`
  # ask of an exposure: `action` ("GraphQL Invoice", "GraphQL User.email"),
  # op (always read), `resource`, `field` (the Ruby name, as field policies
  # and restrictions name it), `guard` (the type's own check on the object,
  # or the field's, as a lower bound), `basis`, `locations` (the type's
  # class, or the field's `field` call) and `rules` (the type check,
  # "Types::UserType#authorized?", which `public_action` can name). `graph`
  # is the `GraphqlModel` the check belongs to, which renders the shared
  # part of the model and explains witnesses.
  GraphqlCheck = Struct.new(:type, :graphql_name, :resource, :field, :field_graphql_name, :guard, :basis,
                            :locations, :rules, :graph, keyword_init: true) do
    def graphql? = true
    def op = :read

    def action = field ? "GraphQL #{graphql_name}.#{field_graphql_name}" : "GraphQL #{graphql_name}"

    def check_name = "reach_#{name_suffix}"

    def name_suffix
      base = Naming.identifier(graphql_name)
      field && (name = field_graphql_name) ? "#{base}_#{Naming.identifier(name)}" : base
    end

    # What it reads: "Invoice", or "User.email" for a field.
    def target = field ? "#{resource}.#{field}" : resource

    def to_s = "#{action} (read #{target}, guard: #{guard})"

    # The query a client would send to reach the witness (`GraphqlModel#path`).
    def path(instance) = graph.path(self, instance)

    # As `Exposure#digest`: the check, the whole GraphQL part of the model
    # (any type or field check can change what is reachable), the public
    # action its type check has, the field's policy and the restrictions
    # covering it.
    def digest(mapping)
      action = mapping.public_action_for(rules)
      restrictions = mapping.restrictions_for(self).map do |restriction|
        [restriction.name, restriction.covering(self).map(&:to_s)]
      end
      parts = [check_name, resource, field, guard.to_s, graph.fingerprint(mapping), action&.audience.to_s,
               action&.condition.to_s, mapping.field_policy_for(resource, field)&.guard.to_s, restrictions]
      Digest::SHA256.hexdigest(JSON.generate(parts))
    end
  end
end
