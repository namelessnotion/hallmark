# typed: strict

module Hallmark
  # What an analysis checks: an entry point's exposure, or a GraphQL
  # reachability check; both answer what reports and watch ask.
  AnyExposure = T.type_alias { T.any(Exposure, GraphqlCheck) }

  class GraphqlCheck
    # The type's Ruby class name ("Types::InvoiceType")
    sig { returns(String) }
    def type; end

    # The type's GraphQL name ("Invoice")
    sig { returns(String) }
    def graphql_name; end

    sig { returns(String) }
    def resource; end

    # The field's Ruby name, as field policies name it; nil for the type's check
    sig { returns(T.nilable(String)) }
    def field; end

    sig { returns(T.nilable(String)) }
    def field_graphql_name; end

    # The type's (or the field's) own check, as a lower bound
    sig { returns(Guard) }
    def guard; end

    sig { returns(T.nilable(String)) }
    def basis; end

    sig { returns(T::Array[String]) }
    def locations; end

    sig { returns(T::Array[String]) }
    def rules; end

    sig { returns(GraphqlModel) }
    def graph; end

    sig do
      params(type: String, graphql_name: String, resource: String, field: T.nilable(String),
             field_graphql_name: T.nilable(String), guard: Guard, basis: T.nilable(String),
             locations: T::Array[String], rules: T::Array[String], graph: GraphqlModel).void
    end
    def initialize(type:, graphql_name:, resource:, field:, field_graphql_name:, guard:, basis:, locations:, rules:,
                   graph:); end

    sig { returns(T::Boolean) }
    def graphql?; end

    sig { returns(T::Boolean) }
    def list?; end

    # "read Invoice", as `Exposure#doing`
    sig { returns(String) }
    def doing; end

    sig { returns(Symbol) }
    def op; end

    sig { returns(String) }
    def action; end

    sig { returns(String) }
    def check_name; end

    sig { returns(String) }
    def name_suffix; end

    sig { returns(String) }
    def target; end

    sig { returns(String) }
    def to_s; end

    sig { params(instance: Receipt::Instance).returns(T.nilable(String)) }
    def path(instance); end

    sig { params(mapping: Mapping).returns(String) }
    def digest(mapping); end
  end
end
