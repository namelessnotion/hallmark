# typed: strict

module Hallmark
  module ListScope
    PUNDIT_RULE = T.let(T.unsafe(nil), String)
    GRAPHQL_RULE = T.let(T.unsafe(nil), String)
    RELATION = T.let(T.unsafe(nil), String)
    NOT_RECORDS = T.let(T.unsafe(nil), T::Array[String])
    RECORDS_READ = T.let(T.unsafe(nil), Integer)

    module_function

    sig { params(type: T.any(String, Symbol), name: T.any(String, Symbol)).returns(String) }
    def action_policy_rule(type, name); end

    sig { params(mapping: Mapping, resource_name: String, guard: Guard).returns(T::Boolean) }
    def across_tenants?(mapping, resource_name, guard); end

    sig { params(resource_name: String).returns(String) }
    def question(resource_name); end

    # LinkPolicy::Scope -> "LinkPolicy"; nil for another name
    sig { params(scope_class: T.nilable(String)).returns(T.nilable(String)) }
    def pundit_policy(scope_class); end
  end
end
