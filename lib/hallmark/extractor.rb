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
    # Directories read, relative to the root.
    DIRS = %w[app/policies].freeze

    # One rule as read from code, checked on records of `resource` (nil when
    # the mapping maps no resource for it, and the rule is not checked).
    Extracted = Struct.new(:policy, :rule, :resource, :guard, :location, keyword_init: true) do
      def key = "#{policy}##{rule}"
      def lower = guard.lower
      def upper = guard.upper
      def exact? = !guard.opaque?
      def opaque_leaves = guard.opaque_leaves
    end

    # An extractor for the app at `root`, or nil when there is no policy
    # code there or HALLMARK_EXTRACT (or `c.extract`) turned extraction off.
    def self.load(mapping, root = Hallmark.configuration.root)
      return nil unless Hallmark.configuration.extract && root
      return nil unless DIRS.any? { |dir| File.directory?(File.join(root, dir)) }

      new(mapping, root)
    end

    attr_reader :root

    def initialize(mapping, root)
      @mapping = mapping
      @root = File.expand_path(root)
      @index = SourceIndex.new(@root, DIRS)
      @translator = MethodTranslator.new(@index, Terms.new(mapping))
      @cache = {}
    end

    # Every rule each policy class defines or aliases, sorted by key.
    def rules
      @index.policies.flat_map do |policy|
        @index.rules(policy).filter_map { |rule| fetch(policy, rule) }
      end
    end

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
      guard = @translator.rule(policy, rule, resource)
      return nil unless guard

      method = @index.find_method(policy, rule)
      Extracted.new(policy: policy, rule: rule, resource: resource, guard: guard,
                    location: method&.location || "#{@index.scopes.fetch(policy).name} (default rule)")
    end

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
require_relative "extractor/terms"
require_relative "extractor/method_translator"
