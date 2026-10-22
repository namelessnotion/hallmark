# typed: strict
# frozen_string_literal: true

module Hallmark
  # How list scopes are named (phase 3 step 7), the same in stamps and in
  # what the extractor reads, so a scope's stamps and its code meet in one
  # unit: Pundit's scope is the policy's `Scope#resolve` ("LinkPolicy",
  # "Scope#resolve"); an Action Policy scope is named after its declaration
  # ("relation_scope", "relation_scope(:own)", "scope_for(:data)"); a
  # graphql-ruby type's is `scope_items` ("Types::LinkType", "scope_items").
  module ListScope
    PUNDIT_RULE = "Scope#resolve"
    GRAPHQL_RULE = "scope_items"

    # Action Policy's type for `relation_scope`.
    RELATION = "active_record_relation"

    # Action Policy scope types that filter something other than records.
    NOT_RECORDS = %w[action_controller_params params].freeze

    # Records of a list result the collectors read facts from, at most.
    # Each costs about one decision's facts (docs/PLAN.md, "The shipped
    # list scopes").
    RECORDS_READ = 3

    module_function

    # An Action Policy scope's rule name, from its type and name.
    def action_policy_rule(type, name)
      named = name.to_s == "default" ? nil : ":#{name}"
      return "relation_scope#{"(#{named})" if named}" if type.to_s == RELATION

      "scope_for(:#{type}#{", #{named}" if named})"
    end

    # Whether a list guarded by `guard` may show records of a tenant other
    # than the current one, on a resource not mapped `lists:
    # :current_tenant`: a question for coverage, never a failure (M5; a
    # dashboard across tenants can be intended). Read three-valued, so
    # only a guard that certainly keeps to the current tenant (or to
    # records outside tenants) is not asked about.
    def across_tenants?(mapping, resource_name, guard)
      resource = mapping.fetch(resource_name)
      return false unless mapping.tenancy && resource.tenanted? && !resource.lists_current_tenant?

      elsewhere = { Guard.new(:in_current_tenant) => false, Guard.new(:outside_tenants) => false }
      guard.evaluate(elsewhere) != false
    end

    # The question coverage and `hallmark rules` print for such a list.
    def question(resource_name)
      "may list other tenants' records; declare `lists: :current_tenant` on #{resource_name} if it should not"
    end

    # The Pundit policy a scope class belongs to: LinkPolicy::Scope ->
    # LinkPolicy; nil for a class not named `<Policy>::Scope`.
    def pundit_policy(scope_class)
      name = scope_class.to_s
      name.end_with?("::Scope") ? name.delete_suffix("::Scope") : nil
    end
  end
end
