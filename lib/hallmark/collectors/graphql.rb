# typed: strict
# frozen_string_literal: true

module Hallmark
  module Collectors
    # Names the GraphQL field being resolved as the entry point for the
    # decisions made inside it, and stamps graphql-ruby's type-level
    # `authorized?` checks as decisions (phase 3 step 6). Every decision made
    # while a GraphQL query runs used to take the controller's entry point
    # (`GraphqlController#execute`).
    #
    # Entry points are `<RootType>.<field>.<field>...` in GraphQL names
    # (`Query.project.pipelineSchedules`, `Mutation.pipelineScheduleCreate`):
    # list indices dropped, aliases resolved to the field's name, and
    # connection wrappers (`edges`, `nodes`, `node`) dropped below the root,
    # so a root `node(id:)` lookup stays `Query.node`. A decision made in
    # lazy or batched resolution, when no field's resolver is running, takes
    # the operation's root type (`Query`, `Mutation`): a batch loads for
    # many fields at once.
    #
    # graphql-ruby 2.x gets `Trace` through `trace_with`, 1.x `LegacyTracer`
    # through `tracer`; each schema class gets one, at install for those
    # loaded and through a TracePoint for those defined later. A query runs
    # inside the controller's entry point, as one of its own
    # (`Collectors.within_entry_point`), whose name is built only when a
    # decision is stamped: pushing a field sets one fiber-local to a frame
    # made once per query (2.x; 1.x passes the field's path, so it makes one
    # per field), and the name comes from the response path graphql-ruby
    # keeps anyway and the query's document. A query not sampled sets no
    # frame at all.
    module GraphqlHook
      # The fiber-locals: the running query's frame, and the multiplex's
      # Registry while a sampled multiplex runs. Fiber-locals, so a
      # dataloader's fibers (which copy them) keep their own frame.
      FRAME = :hallmark_graphql_frame
      REGISTRY = :hallmark_graphql_registry
      # Fields that only wrap a connection's items.
      WRAPPERS = %w[edges nodes node].freeze
      # Frames named after a field rather than the operation.
      IN_FIELD = %i[field authorized].freeze
      # A sampled query's entry point until its first frame is set.
      PENDING = "GraphQL"

      # Where in a query a decision is made: a field's resolver (:field), a
      # type's check on one value (:authorized), lazy or batched resolution
      # (:lazy), or the query outside any field (:query). `path` is the
      # response path 1.x passes its tracers; under 2.x it is read from the
      # context when a name is needed.
      Frame = Struct.new(:kind, :scope, :path)

      # One query's frames, made once, and the names built for it.
      class Scope
        attr_reader :query, :field, :authorized, :lazy, :outside

        def initialize(query)
          @query = query
          @field = Frame.new(:field, self, nil).freeze
          @authorized = Frame.new(:authorized, self, nil).freeze
          @lazy = Frame.new(:lazy, self, nil).freeze
          @outside = Frame.new(:query, self, nil).freeze
          @names = {}
          @operation = nil
        end

        # The root type's name: "Query", "Mutation".
        def operation
          @operation ||= begin
            kind = @query.selected_operation&.operation_type || "query"
            root = @query.schema.root_type_for_operation(kind)
            (root&.graphql_name || kind.capitalize).to_s.freeze
          end
        end

        # The entry point a decision made in `frame` takes.
        def name(frame)
          return operation unless IN_FIELD.include?(frame.kind)

          path = frame.path || @query.context[:current_path]
          return operation unless path.is_a?(Array)

          keys = path.grep(String)
          @names[keys] ||= path_name(keys).freeze
        end

        # "Query.project.pipelineSchedules" for the response keys
        # `project`, `schedules` (an alias) and `nodes` (a wrapper).
        def path_name(keys)
          parts = [operation]
          selections = root_selections
          keys.each do |key|
            fields = fields_named(selections, key, [])
            name = fields.first&.name || key
            parts << name if parts.size == 1 || !WRAPPERS.include?(name)
            selections = fields.flat_map(&:selections)
          end
          parts.join(".")
        end

        private

        def root_selections = @query.selected_operation&.selections || []

        # Every field node a response key names in a selection set, through
        # inline fragments and fragment spreads (a key may be selected twice
        # with different subselections).
        def fields_named(selections, key, found)
          selections.each do |selection|
            case selection
            when ::GraphQL::Language::Nodes::Field
              found << selection if (selection.alias || selection.name) == key
            when ::GraphQL::Language::Nodes::InlineFragment
              fields_named(selection.selections, key, found)
            when ::GraphQL::Language::Nodes::FragmentSpread
              fragment = @query.fragments[selection.name]
              fields_named(fragment.selections, key, found) if fragment
            end
          end
          found
        end
      end

      # A type's `authorized?` in progress: what it checks, and the frame
      # and decided flag it replaced on this fiber.
      TypeCheck = Struct.new(:type, :object, :context, :previous, :decided)

      # A sampled multiplex: each query's Scope, and the name of the entry
      # point a decision on this fiber takes now. A multiplex of one query
      # (`Schema.execute`) keeps that query's field frame at hand.
      class Registry
        attr_reader :field

        def initialize(multiplex)
          @multiplex = multiplex
          @scopes = {}.compare_by_identity
          @last = nil
          queries = multiplex.queries
          @field = (scope(queries.first).field if queries.size == 1)
        end

        def scope(query)
          last = @last
          return last if last && last.query.equal?(query)

          @last = @scopes[query] ||= Scope.new(query)
        end

        # Called with the hook's own arguments (`execute_field(...)`), of
        # which only the query matters; the block `...` forwards (the
        # field's resolution) is left alone, which `&` says.
        def field_frame(query:, **, &) = scope(query).field
        def lazy_frame(query:, **, &) = scope(query).lazy

        # Starts a type check the app wrote; nil for graphql-ruby's own.
        def type_check(query:, type:, object:, &)
          return nil unless GraphqlHook.custom?(type)

          GraphqlHook.start(scope(query).authorized, type, object, query.context)
        end

        # Outside any frame (the dataloader's own fibers, a batch run for
        # the whole multiplex), the first query's operation.
        def name
          frame = Thread.current[FRAME]
          return frame.scope.name(frame) if frame

          query = @multiplex.queries.first
          query ? scope(query).operation : PENDING
        end

        def entry_point = -> { name }
      end

      # Given to `tracer` (graphql-ruby 1.x, which GitLab at `7ce3a7d` runs):
      # one `trace(key, data)` for every event, with the response path in
      # the field and type events.
      module LegacyTracer
        def self.trace(key, data, &)
          if key == "execute_multiplex"
            return yield unless Collectors.active?

            return GraphqlHook.within_multiplex(data[:multiplex], &)
          end
          return yield unless (registry = Thread.current[REGISTRY])

          event(registry, key, data, &)
        end

        # One event with a sampled multiplex running.
        def self.event(registry, key, data, &)
          case key
          when "execute_query"
            scope = registry.scope(data[:query])
            TenantCheck.compare(scope)
            GraphqlHook.within(scope.outside, &)
          when "execute_query_lazy"
            query = data[:query] || data[:multiplex]&.queries&.first
            query ? GraphqlHook.within(registry.scope(query).lazy, &) : yield
          when "execute_field"
            GraphqlHook.within(Frame.new(:field, registry.scope(data[:query]), data[:path]), &)
          when "execute_field_lazy" then GraphqlHook.within(registry.scope(data[:query]).lazy, &)
          when "authorized", "authorized_lazy" then authorized(registry, data, &)
          else yield
          end
        end

        def self.authorized(registry, data, &)
          context = data[:context]
          frame = Frame.new(:authorized, registry.scope(context.query), data[:path])
          GraphqlHook.authorized(frame, data[:type], data[:object], context, &)
        end
      end

      # G6: a request whose GraphQL context names another current tenant
      # than its controller, when the mapping reads both (`current_tenant
      # ..., controller:` and `graphql current_tenant:`). Only the tenants'
      # classes are recorded, never ids.
      module TenantCheck
        def self.compare(scope)
          return unless (readers = readers(Collectors.current_request&.host))

          host, reader, source = readers
          ours = host.__send__(reader)
          theirs = source.call(scope.query.context)
          return if ours.equal?(theirs) || ours == theirs

          Collectors.context_mismatch!(
            ContextMismatch.new(entry_point: entry_point(host), operation: scope.operation,
                                controller_tenant: class_name(ours), graphql_tenant: class_name(theirs))
          )
        rescue StandardError => e
          Collectors.warn_once(e)
        end

        # The controller, its current tenant reader and the context's.
        def self.readers(host)
          mapping = Collectors.facts&.mapping
          reader = mapping&.current_tenant_controller
          source = mapping&.graphql_context&.current_tenant
          [host, reader, source] if reader && source && host.respond_to?(reader, true)
        end

        def self.class_name(tenant) = tenant&.class&.name

        def self.entry_point(host)
          action = host.respond_to?(:action_name) ? host.action_name : nil
          action ? "#{host.class.name}##{action}" : host.class.name.to_s
        end
      end

      # Prepended on graphql-ruby's ScopeExtension, which runs a list
      # field's return type's `scope_items`: an app's own `scope_items`
      # stamps a list decision under the field's entry point (collectors/
      # lists.rb), as rule `scope_items` of the type.
      module ScopeItems
        def after_resolve(**kwargs)
          result = super
          GraphqlHook.scoped(field, kwargs[:value], result, kwargs[:context])
          result
        end
      end

      class << self
        def install
          return if @installed

          @installed = true
          if defined?(::GraphQL::Schema::Field::ScopeExtension)
            ::GraphQL::Schema::Field::ScopeExtension.prepend(ScopeItems)
          end
          @custom = {}.compare_by_identity
          ObjectSpace.each_object(Class) { |klass| attach(klass) }
          @tracer = TracePoint.new(:end) { |trace| attach(trace.self) }
          @tracer.enable
        end

        # Gives a schema class the tracer for its graphql-ruby, once: a
        # subclass of a schema that has it inherits it. Never raises: it runs
        # while the app loads its classes.
        def attach(klass)
          return unless klass.is_a?(Class) && klass < ::GraphQL::Schema
          # 1.x, or a 2.x schema given the legacy tracer by hand.
          return if klass.tracers.include?(LegacyTracer)

          if klass.respond_to?(:trace_with)
            klass.trace_with(Trace) unless klass.trace_modules_for(:default).include?(Trace)
          else
            klass.tracer(LegacyTracer)
          end
        rescue StandardError => e
          Collectors.warn_once(e)
        end

        # Runs a multiplex as an entry point inside the current one; when
        # it is sampled, decisions in it are named after its fields.
        def within_multiplex(multiplex)
          Collectors.within_entry_point(PENDING) do |request|
            outer = Thread.current[REGISTRY]
            frame = Thread.current[FRAME]
            registry = (Registry.new(multiplex) if request.sampled)
            request.entry_point = registry.entry_point if registry
            Thread.current[REGISTRY] = registry
            Thread.current[FRAME] = nil
            begin
              yield
            ensure
              Thread.current[REGISTRY] = outer
              Thread.current[FRAME] = frame
            end
          end
        end

        # Runs the block with `frame` as this fiber's frame.
        def within(frame)
          previous = Thread.current[FRAME]
          Thread.current[FRAME] = frame
          yield
        ensure
          Thread.current[FRAME] = previous
        end

        # Runs a type's `authorized?` (the block) in `frame` and stamps it,
        # unless a policy library decided inside it (GitLab's types call
        # `Ability.allowed?`, which DeclarativePolicy's hook stamps with this
        # field's entry point), so a type check that only asks a library is
        # stamped once, as the library's rule. graphql-ruby's own
        # `authorized?` (true for any object) is not a check and is not
        # stamped; a lazy result is stamped when `authorized_lazy` gives its
        # value. An exception is a deny, re-raised. 2.x's hooks call the
        # steps themselves (`start`, `finish`, `failed`, `restore`).
        def authorized(frame, type, object, context)
          return yield unless custom?(type)

          check = start(frame, type, object, context)
          begin
            finish(check, yield)
          rescue StandardError => e
            failed(check, e)
            raise
          ensure
            restore(check)
          end
        end

        def start(frame, type, object, context)
          check = TypeCheck.new(type, object, context, Thread.current[FRAME], Thread.current[DECIDED])
          Thread.current[FRAME] = frame
          Thread.current[DECIDED] = false
          check
        end

        # Stamps the check's result; returns it.
        def finish(check, result)
          stamp_type(check, result, nil) unless check.context.schema.lazy?(result)
          result
        end

        def failed(check, error) = stamp_type(check, false, error.class.name)

        def restore(check)
          Thread.current[DECIDED] = check.decided || Thread.current[DECIDED]
          Thread.current[FRAME] = check.previous
        end

        # Whether the app wrote the type's `authorized?`: graphql-ruby's own
        # (true for any object, also on its connection and edge types) is
        # not a check.
        def custom?(type)
          custom = @custom ||= {}.compare_by_identity
          known = custom[type]
          return known unless known.nil?

          owner = Module.instance_method(:name).bind_call(type.method(:authorized?).owner)
          custom[type] = !owner&.start_with?("GraphQL::")
        end

        # Stamps the list a type's own `scope_items` returned. Never raises.
        def scoped(field, value, result, context)
          return if value.nil? || !Collectors.active?

          type = listed_type(field)
          return unless own_scope_items?(type)

          policy = Collectors.recording? ? context_policy(type, context) : nil
          return Collectors.checked! unless policy

          Collectors.list(policy: policy, rule: ListScope::GRAPHQL_RULE, result: result, model: value)
        rescue StandardError => e
          Collectors.warn_once(e)
        end

        private

        # What a list field lists: its type, or a connection's node type, to
        # which the connection's `scope_items` hands its items.
        def listed_type(field)
          type = field.type.unwrap
          type.respond_to?(:node_type) && type.node_type ? type.node_type : type
        end

        # Whether the type's `scope_items` is the app's, not graphql-ruby's
        # pass-through.
        def own_scope_items?(type)
          return false unless type.respond_to?(:scope_items)

          owner = type.method(:scope_items).owner
          name = owner.singleton_class? ? owner.attached_object.inspect : owner.name.to_s
          !name.start_with?("GraphQL::")
        end

        # Stamps one type check, read as a rule `authorized?` of the type's
        # class on the object.
        def stamp_type(check, allowed, raised)
          return if Thread.current[DECIDED] || !Collectors.recording?

          Collectors.decision(policy: context_policy(check.type, check.context), rule: "authorized?",
                              record: check.object, allowed: allowed, raised: raised, enforced: true)
        rescue StandardError => e
          Collectors.warn_once(e)
        end

        # The type, with the user and current tenant the mapping's `graphql`
        # reads off the context (`context[:current_user]` and none without it).
        def context_policy(type, context)
          readers = Collectors.facts&.mapping&.graphql_context
          reader = readers&.current_user
          user = reader ? reader.call(context) : context[:current_user]
          ContextPolicy.new(type.name || type.graphql_name, user, readers&.current_tenant&.call(context))
        end
      end
    end
  end
end

require_relative "graphql_trace"
