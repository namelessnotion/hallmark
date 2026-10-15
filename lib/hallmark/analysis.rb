# frozen_string_literal: true

module Hallmark
  # A named mapping plus the exposures to check against the catalog.
  #
  #   Hallmark.analyze "MediumClone" do
  #     map do
  #       resource "Post", owner: :user
  #       resource "User", kind: :profile
  #     end
  #
  #     writes "PostsController#update", "Post", guard: logged_in & owner
  #   end
  class Analysis
    attr_reader :name, :mapping, :exposures

    def self.build(name, &block)
      analysis = new(name)
      Builder.new(analysis).instance_eval(&block) if block
      analysis.validate!
    end

    def initialize(name)
      @name = name.to_s
      @mapping = Mapping.new
      @exposures = []
    end

    def add_exposure(action:, op:, resource:, guard:)
      raise ConfigurationError, "guard for #{action} must be a Hallmark::Guard" unless guard.is_a?(Guard)

      exposure = Exposure.new(action: action.to_s, op: op, resource: resource.to_s, guard: guard)
      if @exposures.any? { |existing| existing.check_name == exposure.check_name }
        raise ConfigurationError, "#{action} #{op}s more than one resource type; split it into separate actions"
      end

      @exposures << exposure
      exposure
    end

    def validate!
      @exposures.each { |exposure| @mapping.fetch(exposure.resource) }
      @mapping.grants.each { |grant| @mapping.fetch(grant.resource) }
      self
    end

    def run(solver: Solver::CLI.new)
      receipt = solver.check(ModelBuilder.new(self).build)
      Report.new(self, receipt)
    end

    # Evaluation context for the DSL block, so guard helpers and declarations
    # are available without exposing the analysis internals.
    class Builder
      include Guard::DSL

      def initialize(analysis)
        @analysis = analysis
      end

      def map(&)
        @analysis.mapping.instance_eval(&)
      end

      def reads(action, resource, guard:)
        @analysis.add_exposure(action: action, op: :read, resource: resource, guard: guard)
      end

      def writes(action, resource, guard:)
        @analysis.add_exposure(action: action, op: :write, resource: resource, guard: guard)
      end
    end
  end
end
