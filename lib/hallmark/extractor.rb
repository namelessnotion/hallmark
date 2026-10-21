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
      return nil unless (DIRS + Controllers::DIRS).any? { |dir| File.directory?(File.join(root, dir)) }

      new(mapping, root)
    end

    attr_reader :root

    def initialize(mapping, root)
      @mapping = mapping
      @root = File.expand_path(root)
      @index = SourceIndex.new(@root, DIRS)
      terms = Terms.new(mapping)
      @translator = MethodTranslator.new(@index, terms)
      @declarative = DeclarativeTranslator.new(@index, terms, @translator)
      @cache = {}
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
require_relative "extractor/declarative_translator"
require_relative "extractor/controllers"
require_relative "extractor/grape_endpoints"
require_relative "extractor/routes_file"
