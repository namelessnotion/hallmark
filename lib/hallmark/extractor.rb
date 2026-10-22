# typed: strict
# frozen_string_literal: true

require "prism"

module Hallmark
  # Reads guards from policy code (phase 2): parses `app/policies` under an
  # app's root with Prism, never loading it, and translates each Pundit or
  # Action Policy rule into a guard over catalog terms (`MethodTranslator`,
  # with the term table in `Terms`). Calls it cannot read stay in the guard
  # as opaque leaves; `Extracted#lower` is what the rule certainly allows and
  # the only part findings come from (docs/adr/0003).
  #
  #   extractor = Hallmark::Extractor.new(mapping, "/path/to/app")
  #   extractor.fetch("LinkPolicy", "update?")&.lower
  class Extractor
    # Directories read, relative to the root (`ee/app/policies` holds GitLab's
    # EE modules, prepended with `prepend_mod_with`).
    DIRS = %w[app/policies ee/app/policies].freeze

    # One rule as read from code, checked on records of `resource` (nil when
    # the mapping maps no resource for it, and the rule is not checked).
    Extracted = Struct.new(:policy, :rule, :resource, :guard, :location, keyword_init: true) do
      def key = "#{policy}##{rule}"
      def lower = guard.lower
      def upper = guard.upper
      def exact? = !guard.opaque?
      def opaque_leaves = guard.opaque_leaves
    end

    # An extractor for the app at `root`, or nil when there is no policy or
    # controller code there or HALLMARK_EXTRACT (or `c.extract`) turned
    # extraction off.
    def self.load(mapping, root = Hallmark.configuration.root)
      return nil unless Hallmark.configuration.extract && root

      dirs = DIRS + Controllers::DIRS + GraphqlSchema::DIRS
      return nil unless dirs.any? { |dir| File.directory?(File.join(root, dir)) }

      new(mapping, root)
    end

    attr_reader :root

    def initialize(mapping, root)
      @mapping = mapping
      @root = File.expand_path(root)
      @index = SourceIndex.new(@root, DIRS)
      @terms = Terms.new(mapping)
      @translator = MethodTranslator.new(@index, @terms)
      @declarative = DeclarativeTranslator.new(@index, @terms, @translator)
      @cache = {}
      @lists = nil
      @list_cache = {}
      @graphql = nil
      @graphql_read = false
      @controllers = nil
      @grape = nil
      @grape_read = false
      @routes = nil
    end

    # The app's controllers, read on first use (`Controllers`).
    def controllers = @controllers ||= Controllers.new(@mapping, @root)

    # The app's Rails routes as read from `config/routes.rb`, on first use
    # (`RoutesFile`); empty when it has none.
    def routes = @routes ||= RoutesFile.new(@root).routes

    # The app's Grape APIs, read on first use; nil when it has none.
    def grape
      return @grape if @grape_read

      @grape_read = true
      dirs = GrapeEndpoints::DIRS.select { |dir| File.directory?(File.join(@root, dir)) }
      @grape = dirs.empty? ? nil : GrapeEndpoints.new(@mapping, @root)
    end

    # The app's graphql-ruby schema, read on first use (`GraphqlSchema`);
    # nil when it has no `app/graphql`.
    def graphql
      return @graphql if @graphql_read

      @graphql_read = true
      dirs = GraphqlSchema::DIRS.select { |dir| File.directory?(File.join(@root, dir)) }
      return @graphql = nil if dirs.empty?

      index = SourceIndex.new(@root, dirs)
      @graphql = GraphqlSchema.new(index, @mapping, terms: @terms, translator: MethodTranslator.new(index, @terms),
                                                    policies: self)
    end

    # A DeclarativePolicy ability on a record of `resource`, through the
    # resource's policy (Ci::PipelineSchedule's is Ci::PipelineSchedulePolicy);
    # nil when there is no such DeclarativePolicy policy.
    def ability_guard(resource, ability)
      policy = "#{resource}Policy"
      @index.scopes.key?(policy) ? @declarative.ability(policy, ability, resource) : nil
    end

    # A Pundit or Action Policy rule on a record of `resource`, through
    # `policy` or the resource's own; nil when the code has no such rule.
    def rule_guard(resource, rule, policy = nil)
      name = policy || "#{resource}Policy"
      return nil unless @index.scopes.key?(name)
      return @declarative.ability(name, rule, resource) if @index.declarative?(name)

      @translator.rule(name, rule, resource)
    end

    # Every rule each policy class defines or aliases, sorted by key; for a
    # DeclarativePolicy policy, the abilities the mapping gives an op
    # (`rule "ProjectPolicy", :read_project, op: :read`), since abilities
    # have no naming convention.
    def rules
      @index.policies.flat_map do |policy|
        names = @index.declarative?(policy) ? abilities(policy) : @index.rules(policy)
        names.filter_map { |rule| fetch(policy, rule) }
      end
    end

    # Every list scope the code defines (phase 3 step 7), sorted by key:
    # each Pundit `<Policy>::Scope#resolve`, each Action Policy scope
    # declared in a policy or inherited from its ancestors, and each
    # graphql-ruby type's `self.scope_items`. Each is checked on the
    # resource its policy (or type) names; nil when none is mapped.
    def lists
      @lists ||= (pundit_scopes + action_policy_scopes).filter_map do |policy, rule|
        list(policy, rule, resource_for(policy, rule))
      end.concat(graphql&.lists || []).sort_by(&:key)
    end

    # One list scope read on records of `resource` (a stamp may show a
    # scope a parent policy defines, ApplicationPolicy's, on a Link); nil
    # when the code has no such scope.
    def list(policy, rule, resource)
      key = [policy, rule, resource]
      return @list_cache[key] if @list_cache.key?(key)

      @list_cache[key] = read_list(policy, rule, resource)
    end

    # DeclarativePolicy hazards (D3, D4) found in the abilities read so far.
    def lints = @declarative.lints

    # One rule, also one a policy answers only through Action Policy's
    # default rule; nil when the code has no such policy or rule.
    def fetch(policy, rule)
      key = "#{policy}##{rule}"
      return @cache[key] if @cache.key?(key)

      @cache[key] = extract(policy, rule)
    end

    private

    def extract(policy, rule)
      return nil unless @index.scopes.key?(policy)

      resource = resource_for(policy, rule)
      return extract_ability(policy, rule, resource) if @index.declarative?(policy)

      guard = @translator.rule(policy, rule, resource)
      return nil unless guard

      method = @index.find_method(policy, rule)
      Extracted.new(policy: policy, rule: rule, resource: resource, guard: guard,
                    location: method&.location || "#{@index.scopes.fetch(policy).name} (default rule)")
    end

    # Pundit policies whose `Scope` class the code defines, with `resolve`.
    def pundit_scopes
      @index.scopes.keys.sort.filter_map do |name|
        policy = ListScope.pundit_policy(name)
        next unless policy && @index.policies.include?(policy) && !@index.action_policy?(policy)
        next unless @index.find_method(name, "resolve")

        [policy, ListScope::PUNDIT_RULE]
      end
    end

    # Each Action Policy policy's scopes, its own and its ancestors'.
    def action_policy_scopes
      @index.policies.select { |policy| @index.action_policy?(policy) }.flat_map do |policy|
        scope_declarations(policy).keys.map { |rule| [policy, rule] }
      end
    end

    # A policy's scope declarations by rule name, the nearest first:
    # `relation_scope(:name) { |relation| ... }` and `scope_for :type,
    # :name do ... end`, leaving out those that filter params.
    def scope_declarations(policy)
      @index.calls(policy).each_with_object({}) do |call, found|
        rule = scope_rule(call)
        found[rule] ||= call if rule
      end
    end

    def scope_rule(call)
      args = call.arguments.grep(Prism::SymbolNode).map(&:unescaped)
      case call.name
      when :relation_scope then ListScope.action_policy_rule(ListScope::RELATION, args.first || "default")
      when :scope_for
        type = args.first
        type && !ListScope::NOT_RECORDS.include?(type) ? ListScope.action_policy_rule(type, args[1] || "default") : nil
      end
    end

    def read_list(policy, rule, resource)
      if rule == ListScope::PUNDIT_RULE
        scope = "#{policy}::Scope"
        method = @index.find_method(scope, "resolve")
        return nil unless method

        guard = @translator.scope(method, scope, resource, roots: %w[scope @scope])
        return Extracted.new(policy: policy, rule: rule, resource: resource, guard: guard, location: method.location)
      end
      return resource && graphql&.list(policy, resource) if rule == ListScope::GRAPHQL_RULE

      call = @index.action_policy?(policy) ? scope_declarations(policy)[rule] : nil
      call && action_policy_list(policy, rule, resource, call)
    end

    # The block's parameter is the relation; a scope declared with a
    # method instead of a block is not read.
    def action_policy_list(policy, rule, resource, call)
      block = call.node.block
      guard = if block.is_a?(Prism::BlockNode) && (param = block_parameter(block))
                @translator.scope_block(block.body, call.file, policy, resource, roots: [param])
              else
                Guard.new(:opaque, call.node.slice.gsub(/\s+/, " "), call.location)
              end
      Extracted.new(policy: policy, rule: rule, resource: resource, guard: guard, location: call.location)
    end

    def block_parameter(block)
      params = block.parameters
      list = params.is_a?(Prism::BlockParametersNode) ? params.parameters : nil
      first = list&.requireds&.first
      first.is_a?(Prism::RequiredParameterNode) ? first.name.to_s : nil
    end

    # A DeclarativePolicy ability, located at its first enabling rule.
    def extract_ability(policy, ability, resource)
      guard = @declarative.ability(policy, ability, resource)
      return nil unless guard

      first = @index.dp_rules(policy).find { |rule| rule.enables.include?(ability) }
      Extracted.new(policy: policy, rule: ability, resource: resource, guard: guard,
                    location: first ? first.location : "#{policy} (no enabling rule)")
    end

    def abilities(policy) = @mapping.rules.values.select { |rule| rule.policy == policy }.map(&:name)

    # The rule's `resource:` in the mapping, else the policy's name without
    # "Policy" when that resource is mapped (LinkPolicy checks Link), with
    # leading namespaces dropped one at a time (Pundit's `[:admin, link]`
    # finds Admin::LinkPolicy).
    def resource_for(policy, rule)
      declared = @mapping.rules["#{policy}##{rule}"]&.resource
      return declared if declared

      name = policy.delete_suffix("Policy")
      return nil if name == policy

      parts = name.split("::")
      candidates = Array.new(parts.size) { |drop| parts.drop(drop).join("::") }
      candidates.find { |candidate| @mapping.resources.key?(candidate) }
    end
  end
end

require_relative "extractor/source_index"
require_relative "extractor/declarative_index"
require_relative "extractor/terms"
require_relative "extractor/method_translator"
require_relative "extractor/scope_reader"
require_relative "extractor/declarative_translator"
require_relative "extractor/controllers"
require_relative "extractor/grape_endpoints"
require_relative "extractor/routes_file"
require_relative "extractor/graphql_schema"
