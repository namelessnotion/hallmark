# typed: strict
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
  #
  # Or, from the stamps a test run recorded (exposures and guards inferred):
  #
  #   Hallmark.analyze "Storefront" do
  #     map { ... }
  #     stamps "tmp/hallmark"
  #   end
  class Analysis
    attr_reader :name, :mapping, :exposures, :inference

    # `mapping` starts the analysis from a copy of an existing mapping, such as
    # the one `Hallmark.configure { |c| c.map { ... } }` declared for the
    # collectors, so the block's `map` never changes the mapping it was given.
    def self.build(name, mapping: nil, &block)
      analysis = new(name, mapping: mapping&.dup)
      Builder.new(analysis).instance_eval(&block) if block
      analysis.validate!
    end

    def initialize(name, mapping: nil)
      @name = name.to_s
      @mapping = mapping || Mapping.new
      @exposures = []
      @inference = nil
    end

    def add_exposure(action:, op:, resource:, guard:, basis: nil, locations: nil)
      raise ConfigurationError, "guard for #{action} must be a Hallmark::Guard" unless guard.is_a?(Guard)

      exposure = Exposure.new(action: action.to_s, op: op, resource: Naming.class_name(resource), guard: guard,
                              basis: basis, locations: locations)
      if @exposures.any? { |existing| existing.check_name == exposure.check_name }
        raise ConfigurationError, "#{action} is declared twice for #{op} #{exposure.resource}"
      end

      @exposures << exposure
      exposure
    end

    # Adds the exposures inferred from recorded stamps: a StampSet, or a path
    # to a JSONL file or a stamp directory, read for the run `c.run` names
    # (HALLMARK_RUN), else the newest. The mapping must be complete
    # first, since inference reads its resources, rules and roles. Guards
    # read from policy code under `c.root` join in (`Extractor.load`).
    def add_stamps(source)
      raise ConfigurationError, "stamps are declared twice in #{name}" if @inference

      set = source.is_a?(StampSet) ? source : StampSet.load(source.to_s, run: Hallmark.configuration.run)
      @mapping.validate!
      inference = Inference.new(@mapping, set, extractor: Extractor.load(@mapping))
      @inference = inference
      inference.exposures.each do |exposure|
        add_exposure(action: exposure.action, op: exposure.op, resource: exposure.resource, guard: exposure.guard,
                     basis: exposure.basis, locations: exposure.locations)
      end
      inference
    end

    def validate!
      @mapping.validate!
      @exposures.each do |exposure|
        resource = @mapping.fetch(exposure.resource)
        validate_tenants!(exposure)
        if exposure.guard.permits? && !resource.permits?
          raise ConfigurationError, "the guard for #{exposure.action} reads explicit permissions, " \
                                    "but #{resource.name} is mapped without `permits:`"
        end
        validate_outside_tenants!(exposure, resource)
        validate_flags!(exposure.guard, resource, "the guard for #{exposure.action}")
      end
      @mapping.grants.each do |grant|
        condition = grant.condition
        resource = @mapping.fetch(grant.resource)
        validate_flags!(condition, resource, "a grant on #{resource.name}") if condition
      end
      self
    end

    # With no exposures (every observed rule only denied, say) there is
    # nothing to check, so the solver does not start. Without `solver:` the
    # run uses the configured backend (`c.solver`).
    def run(solver: nil)
      return Report.new(self, Receipt.empty) if @exposures.empty?

      Report.new(self, (solver || Hallmark.solver).check(ModelBuilder.new(self).build))
    end

    private

    # Without a tenant, guards cannot read one. With a tenant, users hold
    # only platform roles outside tenants, so any other role checked there
    # could never be held and the check would pass for no reason.
    def validate_tenants!(exposure)
      guard = exposure.guard
      unless @mapping.tenancy
        return if guard.tenants.empty?

        raise ConfigurationError,
              "the guard for #{exposure.action} reads tenants, but the map block declares no `tenant`"
      end

      stray = guard.roles_outside_tenants - @mapping.platform_roles
      return if stray.empty?

      raise ConfigurationError, "the guard for #{exposure.action} checks #{stray.join(", ")} outside any tenant, " \
                                "where users hold only platform roles; pass `tenant:` to the role check " \
                                "or declare `platform_role`"
    end

    # A guard may read only the flags its resource declares.
    def validate_flags!(guard, resource, what)
      stray = guard.flags - resource.flags
      return if stray.empty?

      raise ConfigurationError, "#{what} reads flags #{resource.name} does not declare: #{stray.join(", ")}; " \
                                "add them to its `flags:`"
    end

    # Only a record whose tenant is optional can live outside tenants: for
    # any other resource `outside_tenants` is always true or always false.
    def validate_outside_tenants!(exposure, resource)
      return unless exposure.guard.outside_tenants? && !resource.tenant_optional?

      raise ConfigurationError, "the guard for #{exposure.action} asks whether the record lives outside tenants, " \
                                "but #{resource.name} is mapped without `tenant_optional:`"
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

      # Infers exposures from the stamps a test run recorded; declare it
      # after the map block.
      def stamps(source = Hallmark.configuration.stamps)
        @analysis.add_stamps(source)
      end
    end
  end
end
