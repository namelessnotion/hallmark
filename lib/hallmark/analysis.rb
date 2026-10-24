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
  #
  # Or from a graphql-ruby schema read from source (`graphql_schema`, also
  # added by `stamps` when the app has `app/graphql`): one reachability
  # check per mapped type and per field with a field policy (`GraphqlCheck`).
  #
  # Or from code alone (`from_code`): inference with no stamps, whose
  # entry points are the Rails routes `config/routes.rb` declares and the
  # Grape endpoints `lib/api` defines.
  class Analysis
    attr_reader :name, :mapping, :exposures, :inference, :graphql

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
      @graphql = nil
    end

    # `field:` makes a read of one field of the record (fields exist only on
    # reads; a write of a field is mass assignment, threat 12, not built).
    # `kind: :list` makes a list (`lists`): `guard` says which records the
    # list may hold, and each must be readable. `shown_by` names the
    # serializer field a field exposure read from a REST serializer is.
    def add_exposure(action:, op:, resource:, guard:, basis: nil, locations: nil, rules: nil, field: nil, kind: nil,
                     shown_by: nil)
      raise ConfigurationError, "guard for #{action} must be a Hallmark::Guard" unless guard.is_a?(Guard)

      validate_field!(action, op, field, kind)
      exposure = Exposure.new(action: action.to_s, op: op, resource: Naming.class_name(resource), guard: guard,
                              basis: basis, locations: locations, rules: rules, field: field&.to_s, kind: kind,
                              shown_by: shown_by)
      if @exposures.any? { |existing| existing.check_name == exposure.check_name }
        raise ConfigurationError, "#{action} is declared twice for #{exposure.doing}"
      end

      @exposures << exposure
      exposure
    end

    # Adds a GraphQL check as it is (`GraphqlCheck`), with the model it
    # belongs to.
    def add_check(check)
      name = check.check_name
      raise ConfigurationError, "#{check.action} is declared twice" if @exposures.map(&:check_name).include?(name)

      @graphql ||= check.graph
      @exposures << check
      check
    end

    # Adds the checks of the graphql-ruby schema under `root` (the app root
    # by default): one per mapped type reached and one per field with a
    # field policy. Returns the model, nil when the app has no `app/graphql`.
    def add_graphql(root = Hallmark.configuration.root)
      raise ConfigurationError, "the GraphQL schema is declared twice in #{name}" if @graphql

      @mapping.validate!
      model = Extractor.load(@mapping, root)&.graphql&.model
      return nil unless model

      @graphql = model
      model.checks.each { |check| add_check(check) }
      model
    end

    # Adds the exposures inferred from recorded stamps: a StampSet, or a path
    # to a JSONL file or a stamp directory, read for the run `c.run` names
    # (HALLMARK_RUN), else the newest. The mapping must be complete
    # first, since inference reads its resources, rules and roles. Guards
    # read from policy code under `root` (`c.root` by default) join in
    # (`Extractor.load`).
    def add_stamps(source, root: Hallmark.configuration.root)
      raise ConfigurationError, "stamps are declared twice in #{name}" if @inference

      set = source.is_a?(StampSet) ? source : StampSet.load(source.to_s, run: Hallmark.configuration.run)
      @mapping.validate!
      infer(set, Extractor.load(@mapping, root))
    end

    # Adds the exposures inferred from code alone, with no stamps: the
    # Rails routes `config/routes.rb` declares under `root` (the app root
    # by default) become entry points as routes no test reached do, and
    # Grape endpoints come from `lib/api` as always.
    def add_code(root = Hallmark.configuration.root)
      raise ConfigurationError, "exposures are inferred twice in #{name} (`stamps`, `from_code`)" if @inference

      @mapping.validate!
      extractor = Extractor.load(@mapping, root)
      raise ConfigurationError, "no policy, controller or API code under #{root}" unless extractor

      infer(StampSet.new([], [], extractor.routes), extractor)
    end

    # An exposure or a GraphQL check copied into this analysis, as watch
    # and inference hand them over.
    def add(exposure)
      return add_check(exposure) if exposure.is_a?(GraphqlCheck)

      add_exposure(action: exposure.action, op: exposure.op, resource: exposure.resource, guard: exposure.guard,
                   basis: exposure.basis, locations: exposure.locations, rules: exposure.rules, field: exposure.field,
                   kind: exposure.kind, shown_by: exposure.shown_by)
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
        validate_public_action!(exposure, resource)
      end
      @mapping.grants.each do |grant|
        condition = grant.condition
        resource = @mapping.fetch(grant.resource)
        validate_flags!(condition, resource, "a grant on #{resource.name}") if condition
      end
      @mapping.field_policies.each_value { |policy| validate_field_policy!(policy) }
      validate_graphql!
      self
    end

    # The field exposures with no field policy: each is checked as readable
    # as its record, which the report lists under coverage.
    def fields_without_policy
      @exposures.select { |exposure| exposure.field && !@mapping.field_policy_for(exposure.resource, exposure.field) }
    end

    # With no exposures (every observed rule only denied, say) there is
    # nothing to check, so the solver does not start. Without `solver:` the
    # run uses the configured backend (`c.solver`).
    def run(solver: nil)
      return Report.new(self, Receipt.empty) if @exposures.empty?

      Report.new(self, (solver || Hallmark.solver).check(ModelBuilder.new(self).build))
    end

    private

    def infer(set, extractor)
      inference = Inference.new(@mapping, set, extractor: extractor)
      @inference = inference
      @graphql ||= inference.graphql
      inference.exposures.each { |exposure| add(exposure) }
      inference
    end

    def validate_field!(action, op, field, kind)
      return unless field && (op != :read || kind)

      raise ConfigurationError,
            "#{action} writes or lists the field #{field}; fields exist only on reads (`reads ..., field:`)"
    end

    # Without a tenant, guards cannot read one. With a tenant, users hold
    # only platform roles outside tenants, so any other role checked there
    # could never be held and the check would pass for no reason.
    def validate_tenants!(exposure)
      validate_guard_tenants!(exposure.guard, "the guard for #{exposure.action}")
    end

    def validate_guard_tenants!(guard, what)
      unless @mapping.tenancy
        return if guard.tenants.empty?

        raise ConfigurationError, "#{what} reads tenants, but the map block declares no `tenant`"
      end

      stray = guard.roles_outside_tenants - @mapping.platform_roles
      return if stray.empty?

      raise ConfigurationError, "#{what} checks #{stray.join(", ")} outside any tenant, " \
                                "where users hold only platform roles; pass `tenant:` to the role check " \
                                "or declare `platform_role`"
    end

    # A field policy is checked like an exposure's guard: on a mapped
    # resource, with no call Hallmark cannot model, over that resource's
    # flags and permits, and tenant terms only with a `tenant`.
    def validate_field_policy!(policy)
      what = "the field policy for #{policy.key}"
      guard = policy.guard
      resource = @mapping.fetch(policy.resource)
      if guard.opaque?
        raise ConfigurationError, "#{what} holds calls Hallmark cannot model: " \
                                  "#{guard.opaque_leaves.join(", ")}"
      end
      if guard.permits? && !resource.permits?
        raise ConfigurationError,
              "#{what} reads explicit permissions, but #{resource.name} is mapped without `permits:`"
      end
      if guard.outside_tenants? && !resource.tenant_optional?
        raise ConfigurationError, "#{what} asks whether the record lives outside tenants, " \
                                  "but #{resource.name} is mapped without `tenant_optional:`"
      end
      validate_guard_tenants!(guard, what)
      validate_flags!(guard, resource, what)
    end

    # The GraphQL model's guards, read from code, are checked like an
    # exposure's: on their resource's flags and permits, with tenant terms
    # only under a `tenant`.
    def validate_graphql!
      model = @graphql
      return unless model

      model.guards.each do |guard, name|
        resource = @mapping.fetch(name)
        what = "a GraphQL check on #{name}"
        validate_guard_tenants!(guard, what)
        validate_flags!(guard, resource, what)
        if guard.permits? && !resource.permits?
          raise ConfigurationError, "#{what} reads explicit permissions, but #{name} is mapped without `permits:`"
        end
      end
    end

    # A guard may read only the flags its resource declares.
    def validate_flags!(guard, resource, what)
      stray = guard.flags - resource.flags
      return if stray.empty?

      raise ConfigurationError, "#{what} reads flags #{resource.name} does not declare: #{stray.join(", ")}; " \
                                "add them to its `flags:`"
    end

    # A public action's `when:` may read only the flags of the records it
    # is checked on.
    def validate_public_action!(exposure, resource)
      condition = @mapping.public_action_for(exposure.rules || [])&.condition
      validate_flags!(condition, resource, "the public action #{exposure.action}") if condition
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

      # `field:` reads one field of the record, checked against the
      # record's read and the field's policy (`field_policy`).
      def reads(action, resource, guard:, field: nil)
        @analysis.add_exposure(action: action, op: :read, resource: resource, guard: guard, field: field)
      end

      # Fields exist only on reads, so `field:` here raises.
      def writes(action, resource, guard:, field: nil)
        @analysis.add_exposure(action: action, op: :write, resource: resource, guard: guard, field: field)
      end

      # A list an entry point shows (a Pundit `policy_scope`, an Action
      # Policy `authorized_scope`): `guard` says which records it may
      # hold, and each must be readable, and in the current tenant when
      # the resource is mapped `lists: :current_tenant` (M5).
      def lists(action, resource, guard:)
        @analysis.add_exposure(action: action, op: :read, resource: resource, guard: guard, kind: :list)
      end

      # Infers exposures from the stamps a test run recorded; declare it
      # after the map block. `root:` is the app whose code the extractor
      # reads (the app root by default).
      def stamps(source = Hallmark.configuration.stamps, root: Hallmark.configuration.root)
        @analysis.add_stamps(source, root: root)
      end

      # Infers exposures from code alone, with no stamps: entry points are
      # the routes `config/routes.rb` declares and the Grape endpoints in
      # `lib/api` under `root` (the app root by default), each checked as
      # a route no test reached is. Declare it after the map block, in
      # place of `stamps`.
      def from_code(root = Hallmark.configuration.root)
        @analysis.add_code(root)
      end

      # Adds the reachability checks of the graphql-ruby schema in
      # `app/graphql` under `root` (the app root by default); declare it
      # after the map block.
      def graphql_schema(root = Hallmark.configuration.root)
        @analysis.add_graphql(root) || raise(ConfigurationError, "no app/graphql under #{root}")
      end
    end
  end
end
