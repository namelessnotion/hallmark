# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # A graphql-ruby schema read from source with Prism, never loaded (phase
    # 3 step 5): the schema class and its root types, object types with
    # their GraphQL names and the resources they back, fields with what
    # they return (`T`, `[T]`, `T.connection_type`, `type:`, a resolver's
    # `type`), interfaces and unions, Node implementations, and the checks
    # on each:
    #
    # - a type's `self.authorized?(object, context)`, through the method
    #   translator with `object` read as the record and
    #   `context[:current_user]` as the signed-in user;
    # - GitLab's `authorize :ability` on a type (its `authorized?` is
    #   `authorization.ok?`), on a field (`authorize:`) or on a resolver
    #   (`authorizes_object!`, or `authorized_find!` in `resolve`), as the
    #   DeclarativePolicy ability on the object it checks;
    # - a field's own `def authorized?(obj, args, ctx)` in its block;
    # - Action Policy's `authorize:` and `preauthorize:` field options, as
    #   the policy rule on each object the field returns;
    # - `self.scope_items` (`items.where(attr: value)`, `items.select { }`)
    #   as a guard on the members of a list field.
    #
    # A call the translators cannot read is an opaque leaf (docs/adr/0003).
    # `GraphqlModel` turns what this reads into Alloy; `lints` are the
    # static hazards G4 and G5.
    class GraphqlSchema
      DIRS = %w[app/graphql ee/app/graphql].freeze

      # The Relay Node interface, outside the app; `node(id:)` returns any
      # object whose type implements it.
      NODE = "GraphQL::Types::Relay::Node"
      NODE_NAMES = %w[GraphQL::Types::Relay::Node GraphQL::Relay::Node].freeze

      SCHEMA = "GraphQL::Schema"
      INTERFACE = "GraphQL::Schema::Interface"
      UNION = "GraphQL::Schema::Union"

      # Calls that authorize something inside a mutation's `resolve` (G4).
      AUTH_CALLS = %i[authorize authorize! authorized_find! authorized_resource? allowed_to? can? allowed?
                      authorized? check_permission!].freeze

      # One object, interface or union type: `guard` is its own check on an
      # object (`none` when it has none), `scope` its `scope_items` as a
      # guard on list members (nil when it has none), `reauthorize` false
      # under `reauthorize_scoped_objects(false)`.
      Type = Struct.new(:name, :graphql_name, :kind, :resource, :guard, :scope, :reauthorize, :location,
                        keyword_init: true) do
        # Whether the reader found any authorization on it.
        def checked? = guard.kind != :none || !scope.nil?
      end

      # One field of a type. `targets` are the concrete types it returns
      # (an interface's implementers, a union's members; empty for a
      # scalar or a type Hallmark cannot resolve), `via` the interface or
      # union it names. `guard` checks the parent object (`none` when
      # nothing does); `child_checks` hold what checks each returned object
      # (`GraphqlSchema#child_guard` reads them for one target). `scoped`
      # is false for `scope: false`, true for `scope: true`, nil by default.
      Field = Struct.new(:owner, :name, :graphql_name, :targets, :via, :list, :connection, :guard, :child_checks,
                         :scoped, :arguments, :location, keyword_init: true) do
        def key = "#{owner}##{name}"

        # Whether the target type's `scope_items` runs on what it returns:
        # by default on lists and connections only.
        def scoped? = scoped.nil? ? list == true : scoped == true
      end

      # A check on each object a field returns: a policy rule (Action
      # Policy's `authorize:`), DeclarativePolicy abilities (a resolver's
      # `authorized_find!`), or a call Hallmark does not read.
      ChildCheck = Struct.new(:kind, :names, :source, :location, keyword_init: true)

      # What a type expression names: the class (or NODE), and whether it is
      # a list or a connection.
      Target = Struct.new(:name, :list, :connection, keyword_init: true)

      Lint = DeclarativeTranslator::Lint

      def initialize(index, mapping, terms:, translator:, policies:)
        @index = index
        @mapping = mapping
        @terms = terms
        @translator = translator
        @policies = policies
        @types = {}
        @fields = {}
        @implementer_table = nil
        @lints = nil
        @model = nil
      end

      # The class inheriting from GraphQL::Schema, first by name; nil when
      # the code has none.
      def schema = @index.scopes.keys.sort.find { |name| @index.inherits?(name, SCHEMA) }

      # The root type of an operation (:query or :mutation): what the
      # schema class names, else `Types::QueryType` or `Types::MutationType`.
      def root(operation)
        declared_root(operation) || ["Types::#{operation.to_s.capitalize}Type"].find { @index.scopes.key?(_1) }
      end

      def type(name) = @types[name] ||= read_type(name)

      def fields(name) = @fields[name] ||= read_fields(name)

      # The model of this schema for a mapping (memoized: the code does
      # not change during a run).
      def model = @model ||= GraphqlModel.new(@mapping, self)

      # The check a field makes on each object it returns of `target`, a
      # type name: `none` when it makes none.
      def child_guard(field, target)
        resource = type(target).resource
        field.child_checks.reduce(Guard.new(:none)) do |all, check|
          Guard.conjoin(all, child_check_guard(check, resource))
        end
      end

      # Static hazards (docs/PLAN.md, G4 and G5): mutations checked late or
      # not at all, and scopes switched off.
      def lints = @lints ||= (mutation_lints + scope_lints).uniq

      # GraphQL's camelization of a Ruby name, as graphql-ruby does it.
      def self.camelize(name)
        return name unless name.include?("_")

        parts = name.split("_").reject(&:empty?).map(&:capitalize)
        camelized = parts.join
        camelized = camelized[0].to_s.downcase + camelized[1..].to_s
        leading = name[/\A_+/]
        leading ? "#{leading}#{camelized}" : camelized
      end

      private

      def declared_root(operation)
        name = schema
        call = name && @index.scopes.fetch(name).calls.find { |found| found.name == operation }
        target = call&.arguments&.first
        call && target ? class_named(target, call.owner) : nil
      end

      def read_type(name)
        resource = resource_for(name)
        Type.new(name: name, graphql_name: graphql_name_of(name), kind: kind_of(name), resource: resource,
                 guard: type_guard(name, resource), scope: scope_guard(name, resource),
                 reauthorize: reauthorize?(name), location: @index.scopes[name]&.location)
      end

      # The resource the mapping's `graphql_type` names, else the class
      # without `Types::` and `Type` when that resource is mapped
      # (Types::Ci::PipelineScheduleType backs Ci::PipelineSchedule).
      def resource_for(name)
        declared = @mapping.graphql_types[name]
        return declared.resource if declared

        candidate = name.delete_prefix("Types::").delete_suffix("Type")
        @mapping.resources.key?(candidate) ? candidate : nil
      end

      # `graphql_name "X"` in the class body, else graphql-ruby's default:
      # the last part of the class name without `Type`.
      def graphql_name_of(name)
        call = @index.scopes[name]&.calls&.find { |found| found.name == :graphql_name }
        given = call&.arguments&.first
        return given.unescaped if given.is_a?(Prism::StringNode)

        default = name.split("::").last.to_s.sub(/Type\z/, "")
        default.empty? ? name : default
      end

      def kind_of(name)
        return :interface if interface?(name)

        @index.inherits?(name, UNION) ? :union : :object
      end

      def interface?(name)
        @index.ancestors(name).any? do |ancestor|
          @index.scopes.fetch(ancestor).includes.any? { |included| included.delete_prefix("::") == INTERFACE }
        end
      end

      # A type's own check: `self.authorized?` read by the method
      # translator, unless it is GitLab's `authorization.ok?`, which checks
      # the abilities `authorize` declares.
      def type_guard(name, resource)
        method = @index.find_method(name, "self.authorized?")
        if method.nil? || authorization_form?(method)
          location = @index.scopes[name]&.location
          return ability_guard(abilities_of(name), resource, location)
        end

        params = method.node.parameters&.requireds || []
        translate(method, name, resource, record: param_name(params[0]), context: param_name(params[1]))
      end

      # GitLab's `def self.authorized?(object, context) =
      # authorization.ok?(object, context[:current_user])`.
      def authorization_form?(method)
        body = method.node.body
        statement = body.is_a?(Prism::StatementsNode) && body.body.size == 1 ? body.body.first : nil
        receiver = statement.is_a?(Prism::CallNode) ? statement.receiver : nil
        statement.is_a?(Prism::CallNode) && statement.name == :ok? && receiver.is_a?(Prism::CallNode) &&
          receiver.name == :authorization
      end

      # The abilities the nearest `authorize :a, :b` declares (GitLab's
      # types: a subclass's declaration replaces its parent's).
      def abilities_of(name)
        @index.ancestors(name).each do |ancestor|
          found = authorize_symbols(@index.scopes.fetch(ancestor).calls)
          return found if found.any?
        end
        []
      end

      def authorize_symbols(calls)
        calls.select { |call| call.name == :authorize }.flat_map { |call| call.arguments.filter_map { symbol(_1) } }
      end

      # Each ability on the record of `resource`, through its policy; an
      # ability Hallmark cannot read (no mapped resource, no policy) is an
      # opaque leaf.
      def ability_guard(abilities, resource, location)
        abilities.reduce(Guard.new(:none)) do |all, ability|
          read = resource ? @policies.ability_guard(resource, ability) : nil
          Guard.conjoin(all, read || Guard.new(:opaque, "authorize :#{ability}", location))
        end
      end

      # A check's body through the method translator, with graphql-ruby's
      # names renamed: the checked object to `record`, the context's user
      # and current tenant to the mapping's names. graphql-ruby's own
      # `authorized?` returns true, so a `super` with nothing above it in
      # the app reads as no check.
      def translate(method, klass, resource, record:, context:)
        body = method.node.body
        return Guard.new(:never) unless body

        aliases = context_aliases
        aliases[record] = "record" if record
        aliases[context] = "context" if context
        without_super(@translator.expression(body, method, klass, resource, aliases: aliases))
      end

      def context_aliases
        user = @mapping.principal_source.is_a?(Symbol) ? @mapping.principal_source.to_s : "user"
        aliases = { "object" => "record", "context[:current_user]" => user, "current_user" => user }
        tenant = @mapping.current_tenant_source
        aliases["context[:#{tenant}]"] = tenant.to_s if tenant.is_a?(Symbol)
        aliases
      end

      def without_super(guard)
        case guard.kind
        when :opaque then guard.operands[0] == "super" ? Guard.new(:none) : guard
        when :and then Guard.conjoin(without_super(guard.operands[0]), without_super(guard.operands[1]))
        when :or then Guard.disjoin(without_super(guard.operands[0]), without_super(guard.operands[1]))
        when :not then Guard.negate(without_super(guard.operands[0]))
        else guard
        end
      end

      def param_name(node)
        node.is_a?(Prism::RequiredParameterNode) ? node.name.to_s : nil
      end

      # `self.scope_items(items, context)` as a guard on each member: the
      # items themselves (no filter), `where(attr: value)` through the
      # term table, `select { |item| ... }` through the translator, `none`.
      def scope_guard(name, resource)
        method = @index.find_method(name, "self.scope_items")
        return nil unless method

        body = method.node.body
        last = body.is_a?(Prism::StatementsNode) ? body.body.last : nil
        params = method.node.parameters&.requireds || []
        names = { items: param_name(params[0]), context: param_name(params[1]) }
        last ? relation_guard(last, method, name, resource, names) : Guard.new(:never)
      end

      def relation_guard(node, method, klass, resource, names)
        return Guard.new(:none) if node.is_a?(Prism::LocalVariableReadNode) && node.name.to_s == names[:items]
        return opaque_node(node, method) unless node.is_a?(Prism::CallNode) && node.receiver

        receiver = node.receiver || raise(ArgumentError, "a relation call needs a receiver")
        case node.name
        when :all then relation_guard(receiver, method, klass, resource, names)
        when :none then Guard.new(:never)
        when :where
          Guard.conjoin(relation_guard(receiver, method, klass, resource, names), where_guard(node, method, resource))
        when :select, :filter
          Guard.conjoin(relation_guard(receiver, method, klass, resource, names),
                        select_guard(node, method, klass, resource, names))
        else opaque_node(node, method)
        end
      end

      # `where(organization: context[:current_organization])`: each pair
      # as the term for `record.attr == value`.
      def where_guard(node, method, resource)
        hash = node.arguments&.arguments&.first
        return opaque_node(node, method) unless hash.is_a?(Prism::KeywordHashNode)

        canonical = Canonical.new({}, context_aliases)
        hash.elements.reduce(Guard.new(:none)) do |all, pair|
          key = pair.is_a?(Prism::AssocNode) ? symbol(pair.key) : nil
          found = key && @terms.compare("record.#{key}", canonical.render(pair.value), resource)
          Guard.conjoin(all, found || opaque_node(pair, method))
        end
      end

      def select_guard(node, method, klass, resource, names)
        block = node.block
        param = block.is_a?(Prism::BlockNode) ? block_param(block) : nil
        body = block.is_a?(Prism::BlockNode) ? block.body : nil
        return opaque_node(node, method) unless param && body

        aliases = context_aliases.merge(param => "record")
        context = names[:context]
        aliases[context] = "context" if context
        without_super(@translator.expression(body, method, klass, resource, aliases: aliases))
      end

      def block_param(block)
        params = block.parameters
        list = params.is_a?(Prism::BlockParametersNode) ? params.parameters : nil
        param_name(list&.requireds&.first)
      end

      def reauthorize?(name)
        @index.calls(name).none? do |call|
          call.name == :reauthorize_scoped_objects && call.arguments.first.is_a?(Prism::FalseNode)
        end
      end

      def opaque_node(node, method)
        Guard.new(:opaque, node.slice.gsub(/\s+/, " "), "#{method.file}:#{node.location.start_line}")
      end

      # Fields declared on the type, its app ancestors and the interfaces
      # it implements, nearest first, one per name; plus `node` and `nodes`
      # from graphql-ruby's HasNodeField and HasNodesField.
      def read_fields(name)
        found = {}
        (@index.calls(name) + interfaces_of(name).flat_map { |interface| @index.calls(interface) }).each do |call|
          next unless call.name == :field

          field = read_field(call, name)
          found[field.name] ||= field if field
        end
        found.values + node_fields(name)
      end

      def interfaces_of(name)
        named = @index.calls(name).select { |call| call.name == :implements }.flat_map do |call|
          call.arguments.filter_map { |arg| interface_named(arg, call.owner) }
        end
        named.select { |interface| @index.scopes.key?(interface) }
      end

      # `implements X` (or 1.x's `implements GraphQL::Relay::Node.interface`)
      # as the interface's name: an app module, or NODE.
      def interface_named(node, owner)
        node = node.receiver if node.is_a?(Prism::CallNode) && node.name == :interface && node.receiver
        class_named(node, owner)
      end

      def node_fields(name)
        includes = @index.ancestors(name).flat_map { |ancestor| @index.scopes.fetch(ancestor).includes }
        location = @index.scopes[name]&.location
        fields = []
        if includes.any? { |included| included.end_with?("Relay::HasNodeField") }
          fields << node_field(name, "node", false, location)
        end
        fields << node_field(name, "nodes", true, location) if includes.any? { _1.end_with?("Relay::HasNodesField") }
        fields
      end

      def node_field(owner, name, list, location)
        Field.new(owner: owner, name: name, graphql_name: name, targets: implementers(NODE), via: "Node", list: list,
                  connection: false, guard: Guard.new(:none), child_checks: [], scoped: nil,
                  arguments: [list ? "ids" : "id"], location: location)
      end

      def read_field(call, owner)
        args = call.arguments
        name = symbol(args[0])
        return nil unless name

        resolver = resolver_of(call)
        target = field_target(call, resolver)
        targets, via = target ? targets_of(target.name) : [[], nil]
        Field.new(owner: owner, name: name, graphql_name: field_graphql_name(call, name), targets: targets,
                  via: via, list: target&.list == true, connection: target&.connection == true,
                  guard: field_guard(call, owner, resolver), child_checks: child_checks(call, resolver),
                  scoped: scoped_option(call), arguments: field_arguments(call, resolver), location: call.location)
      end

      def field_graphql_name(call, name)
        given = keyword(call, :graphql_name)
        return given.unescaped if given.is_a?(Prism::StringNode)

        keyword(call, :camelize).is_a?(Prism::FalseNode) ? name : GraphqlSchema.camelize(name)
      end

      def field_target(call, resolver)
        args = call.arguments
        node = keyword(call, :type) || (args[1] unless args[1].is_a?(Prism::KeywordHashNode))
        return type_expression(node, call.owner) if node

        resolver ? resolver_type(resolver) : nil
      end

      # A type expression: `T`, `[T]`, `T.connection_type`, `"T"`.
      def type_expression(node, owner)
        case node
        when Prism::ArrayNode
          inner = node.elements.first
          found = inner && type_expression(inner, owner)
          found && Target.new(name: found.name, list: true, connection: found.connection)
        when Prism::CallNode then type_call(node, owner)
        else
          name = class_named(node, owner)
          name && Target.new(name: name, list: false, connection: false)
        end
      end

      def type_call(node, owner)
        receiver = node.receiver
        inner = receiver && type_expression(receiver, owner)
        return nil unless inner

        case node.name
        when :connection_type then Target.new(name: inner.name, list: true, connection: true)
        when :to_list_type then Target.new(name: inner.name, list: true, connection: false)
        when :to_non_null_type then inner
        end
      end

      # A constant (or a String naming one) as an indexed class, an EE
      # module read as the class it is prepended to, or NODE; nil for a
      # class outside the app (a scalar such as GraphQL::Types::String).
      def class_named(node, owner)
        text = case node
               when Prism::ConstantReadNode, Prism::ConstantPathNode then node.slice
               when Prism::StringNode then node.unescaped
               end
        return nil unless text
        return NODE if NODE_NAMES.include?(text.delete_prefix("::"))

        found = @index.resolve_constant(text, owner.split("::"))
        found ? host_of(found) : nil
      end

      def host_of(name)
        host = name.delete_prefix("EE::")
        host != name && @index.scopes[host]&.prepends&.include?(name) ? host : name
      end

      # The concrete types behind a type name, and the interface or union
      # named, if any.
      def targets_of(name)
        return [implementers(name), "Node"] if name == NODE

        case type(name).kind
        when :interface then [implementers(name), type(name).graphql_name]
        when :union then [union_members(name), type(name).graphql_name]
        else [[name], nil]
        end
      end

      def implementers(interface) = implementer_table.fetch(interface, [])

      def implementer_table
        @implementer_table ||= @index.scopes.keys.sort.each_with_object({}) do |name, table|
          implemented(name).each { |interface| (table[interface] ||= []) << name }
        end
      end

      # The interfaces (app modules or NODE) a class's `implements` name.
      def implemented(name)
        named = @index.calls(name).select { |call| call.name == :implements }.flat_map do |call|
          call.arguments.filter_map { |arg| interface_named(arg, call.owner) }
        end
        named.uniq
      end

      def union_members(name)
        @index.calls(name).select { |call| call.name == :possible_types }.flat_map do |call|
          call.arguments.filter_map { |arg| class_named(arg, call.owner) }
        end.uniq
      end

      # `resolver: R` (or `R.single`) as R's class name.
      def resolver_of(call)
        node = keyword(call, :resolver)
        node = node.receiver if node.is_a?(Prism::CallNode) && node.receiver
        node && class_named(node, call.owner)
      end

      def resolver_type(resolver)
        call = @index.calls(resolver).find { |found| found.name == :type }
        node = call&.arguments&.first
        node && call ? type_expression(node, call.owner) : nil
      end

      # Checks on the parent object: the field's own `def authorized?` in
      # its block, GitLab's `authorize:` abilities, and a resolver that
      # authorizes the object it is resolved on (`authorizes_object!`).
      def field_guard(call, owner, resolver)
        resource = type(owner).resource
        guard = block_guard(call, owner, resource)
        abilities = gitlab_abilities(keyword(call, :authorize))
        guard = Guard.conjoin(guard, ability_guard(abilities, resource, call.location)) if abilities.any?
        if resolver && authorizes_object?(resolver)
          guard = Guard.conjoin(guard, ability_guard(resolver_abilities(resolver), resource, call.location))
        end
        guard
      end

      def block_guard(call, owner, resource)
        block = call.node.block
        body = block.is_a?(Prism::BlockNode) ? block.body : nil
        statements = body.is_a?(Prism::StatementsNode) ? body.body : []
        definition = statements.find { |node| node.is_a?(Prism::DefNode) && node.name == :authorized? }
        return Guard.new(:none) unless definition.is_a?(Prism::DefNode)

        method = SourceIndex::Method.new(name: "authorized?", node: definition, file: call.file, visibility: :public,
                                         owner: owner)
        params = definition.parameters&.requireds || []
        translate(method, owner, resource, record: param_name(params[0]), context: param_name(params[2]))
      end

      # GitLab's `authorize: :read_x` (abilities, no `?`); Action Policy's
      # `authorize:` (true, a rule, or options) checks the child instead.
      def gitlab_abilities(node)
        names = case node
                when Prism::SymbolNode then [node.unescaped]
                when Prism::ArrayNode then node.elements.filter_map { |element| symbol(element) }
                else []
                end
        names.none? { |name| name.end_with?("?") } ? names : []
      end

      def authorizes_object?(resolver)
        @index.calls(resolver).any? { |call| call.name == :authorizes_object! } ||
          literal_true?(@index.find_method(resolver, "self.authorizes_object?"))
      end

      def literal_true?(method)
        body = method&.node&.body
        body.is_a?(Prism::StatementsNode) && body.body.last.is_a?(Prism::TrueNode)
      end

      # GitLab resolvers add their parent's permissions to their own.
      def resolver_abilities(resolver) = authorize_symbols(@index.calls(resolver)).uniq

      def child_checks(call, resolver)
        checks = []
        location = call.location
        %i[authorize preauthorize].each do |option|
          node = keyword(call, option)
          checks << action_policy_check(node, location) if node && action_policy?(node)
        end
        checks << ChildCheck.new(kind: :opaque, names: [], source: "authorized_scope:", location: location) if
          keyword(call, :authorized_scope)
        checks.concat(resolver_child_checks(resolver)) if resolver
        checks
      end

      def action_policy?(node)
        node.is_a?(Prism::TrueNode) || node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode) ||
          (node.is_a?(Prism::SymbolNode) && node.unescaped.end_with?("?"))
      end

      # `authorize: true` checks `show?`; `authorize: :rule?` or
      # `authorize: {to: :rule?, with: SomePolicy}` name another rule and
      # policy.
      def action_policy_check(node, location)
        rule = "show?"
        policy = nil
        if node.is_a?(Prism::SymbolNode)
          rule = node.unescaped
        elsif node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
          rule = symbol(pair_value(node, "to")) || rule
          with = pair_value(node, "with")
          policy = with&.slice&.delete_prefix("::")
        end
        ChildCheck.new(kind: :rule, names: [rule, policy].compact, source: node.slice, location: location)
      end

      def pair_value(hash, key)
        pair = hash.elements.find { |element| element.is_a?(Prism::AssocNode) && symbol(element.key) == key }
        pair.is_a?(Prism::AssocNode) ? pair.value : nil
      end

      # A GitLab resolver that does not authorize its parent but calls
      # `authorized_find!` or `authorize!` in `resolve` checks what it
      # returns.
      def resolver_child_checks(resolver)
        abilities = resolver_abilities(resolver)
        return [] if abilities.empty? || authorizes_object?(resolver)

        resolve = @index.find_method(resolver, "resolve")
        return [] unless resolve && calls_any?(resolve.node, %i[authorized_find! authorize!])

        [ChildCheck.new(kind: :abilities, names: abilities, source: "authorize #{abilities.join(", ")}",
                        location: resolve.location)]
      end

      def child_check_guard(check, resource)
        location = check.location
        case check.kind
        when :rule
          read = resource ? @policies.rule_guard(resource, check.names[0].to_s, check.names[1]) : nil
          read || Guard.new(:opaque, check.source, location)
        when :abilities then ability_guard(check.names, resource, location)
        else Guard.new(:opaque, check.source, location)
        end
      end

      def scoped_option(call)
        node = keyword(call, :scope)
        return false if node.is_a?(Prism::FalseNode)

        node.is_a?(Prism::TrueNode) || nil
      end

      # Required arguments, in GraphQL names, for printing the query a
      # client would send: the field block's and the resolver's.
      def field_arguments(call, resolver)
        calls = block_calls(call.node)
        calls += @index.calls(resolver).map(&:node) if resolver
        calls.select { |node| node.name == :argument }.filter_map { |node| required_argument(node) }.uniq
      end

      def required_argument(node)
        args = node.arguments&.arguments || []
        name = symbol(args[0])
        hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
        required = hash.is_a?(Prism::KeywordHashNode) ? pair_value(hash, "required") : nil
        name && !required.is_a?(Prism::FalseNode) ? GraphqlSchema.camelize(name) : nil
      end

      def block_calls(node)
        block = node.block
        body = block.is_a?(Prism::BlockNode) ? block.body : nil
        statements = body.is_a?(Prism::StatementsNode) ? body.body : []
        statements.grep(Prism::CallNode).select { |statement| statement.receiver.nil? }
      end

      # G4: every mutation the Mutation root mounts (`field ..., mutation:`,
      # GitLab's `mount_mutation`) must check something of its own.
      def mutation_lints
        mutations.flat_map { |mutation, call| mutation_hazards(mutation, call) }
      end

      def mutations
        root_name = root(:mutation)
        return [] unless root_name

        @index.calls(root_name).filter_map do |call|
          node = mutation_node(call)
          found = node && class_named(node, call.owner)
          [found, call] if found && @index.scopes.key?(found)
        end.uniq(&:first)
      end

      def mutation_node(call)
        case call.name
        when :field then keyword(call, :mutation) || keyword(call, :resolver)
        when :mount_mutation, :mount_aliased_mutation then call.arguments.find { |arg| !arg.is_a?(Prism::SymbolNode) }
        end
      end

      def mutation_hazards(mutation, call)
        hazards = []
        if (option = keyword(call, :authorize)) && action_policy?(option)
          hazards << Lint.new(kind: "G4", location: call.location,
                              message: "#{mutation} is mounted with Action Policy's `authorize:`, which runs after " \
                                       "the mutation has executed; check in `authorized?` instead")
        end
        unless mutation_checked?(mutation)
          hazards << Lint.new(kind: "G4", location: @index.scopes.fetch(mutation).location || call.location,
                              message: "#{mutation} has no `ready?`, `authorized?` or `authorize` of its own and " \
                                       "authorizes nothing in `resolve`")
        end
        hazards + load_hazards(mutation)
      end

      # Checks the mutation or the classes between it and the app's base
      # mutation declare (a base class's check is not about the object),
      # or an authorization call in `resolve` and the helpers it calls.
      def mutation_checked?(mutation)
        own = own_ancestors(mutation)
        declared = own.any? do |name|
          scope = @index.scopes.fetch(name)
          %w[ready? authorized? self.authorized?].any? { |method| scope.defs.key?(method) } ||
            scope.calls.any? { |call| call.name == :authorize }
        end
        resolve = @index.find_method(mutation, "resolve")
        declared || (!resolve.nil? && authorizes_in?(mutation, resolve.node, 0))
      end

      # The ancestors up to the app's topmost class (the base mutation),
      # which is left out with what it includes.
      def own_ancestors(name)
        chain = @index.ancestors(name)
        base = chain.reverse.find { |ancestor| @index.scopes.fetch(ancestor).module == false }
        base && base != name ? chain.take_while { |ancestor| ancestor != base } : chain
      end

      def authorizes_in?(klass, node, depth)
        calls(node).any? do |call|
          name = call.name
          next true if AUTH_CALLS.include?(name) || name.to_s.start_with?("authoriz")
          next false unless call.receiver.nil? && depth < 2

          helper = @index.find_method(klass, name.to_s)
          !helper.nil? && authorizes_in?(klass, helper.node, depth + 1)
        end
      end

      def calls_any?(node, names) = calls(node).any? { |call| names.include?(call.name) }

      def calls(node)
        found = []
        stack = [node]
        while (current = stack.shift)
          found << current if current.is_a?(Prism::CallNode)
          stack.concat(current.compact_child_nodes)
        end
        found
      end

      # A `load_<name>` override for a `loads:` argument that neither calls
      # `super` nor authorizes anything skips the loaded type's check.
      def load_hazards(mutation)
        loads = @index.calls(mutation).select { |call| call.name == :argument && keyword(call, :loads) }
        loads.filter_map do |call|
          name = symbol(call.arguments.first)
          base = name&.sub(/_ids?\z/, "")
          method = base && @index.find_method(mutation, "load_#{base}")
          next unless method && !skips_nothing?(mutation, method)

          Lint.new(kind: "G4", location: method.location,
                   message: "#{mutation}#load_#{base} loads `#{name}` without `super`, skipping the loaded type's " \
                            "`authorized?`")
        end
      end

      def skips_nothing?(mutation, method) = contains_super?(method.node) || authorizes_in?(mutation, method.node, 0)

      def contains_super?(node)
        return true if node.is_a?(Prism::SuperNode) || node.is_a?(Prism::ForwardingSuperNode)

        node.compact_child_nodes.any? { |child| contains_super?(child) }
      end

      # G5: `scope: false` on a list field, or `reauthorize_scoped_objects
      # (false)` with a `scope_items` that reads no tenant.
      def scope_lints
        @index.scopes.keys.sort.flat_map do |name|
          unscoped = @index.scopes.fetch(name).calls.select { |call| call.name == :field && unscoped_list?(call) }
          lints = unscoped.map do |call|
            Lint.new(kind: "G5", location: call.location,
                     message: "the list field #{symbol(call.arguments.first)} on #{name} sets `scope: false`, so its " \
                              "type's `scope_items` never filters it")
          end
          lints + reauthorize_lints(name)
        end
      end

      def unscoped_list?(call)
        return false unless keyword(call, :scope).is_a?(Prism::FalseNode)

        target = field_target(call, resolver_of(call))
        target.nil? || target.list == true
      end

      def reauthorize_lints(name)
        scope = @index.scopes.fetch(name)
        call = scope.calls.find { |found| found.name == :reauthorize_scoped_objects }
        return [] unless call && call.arguments.first.is_a?(Prism::FalseNode)

        return [] if scope_guard(name, resource_for(name))&.tenants&.any?

        [Lint.new(kind: "G5", location: call.location,
                  message: "#{name} turns off `reauthorize_scoped_objects`, and its `scope_items` reads no tenant " \
                           "Hallmark can see, so list members are never checked against the current tenant")]
      end

      def keyword(call, key)
        args = call.is_a?(SourceIndex::Call) ? call.arguments : (call.arguments&.arguments || [])
        hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
        hash.is_a?(Prism::KeywordHashNode) ? pair_value(hash, key.to_s) : nil
      end

      def symbol(node) = node.is_a?(Prism::SymbolNode) ? node.unescaped : nil
    end
  end
end
