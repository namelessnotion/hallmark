# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # The check a type's own field class makes on each of its fields (phase
    # 3 step 10, for gitlab-org/gitlab!129831): `field_class X` on a type
    # whose superclass's types use another field class B, and an
    # `authorized?(object, args, ctx)` defined on X or a class between X
    # and B. B is the app's default (GitLab's Types::BaseField, whose check
    # reads the field's own `authorize:`, which `GraphqlSchema` already
    # reads), so a type that only inherits the default gets nothing here,
    # and `super` passes.
    #
    # The body is read by the method translator, with `object` as the
    # record and the context's user as the user, once per field, so that
    # `OPEN.include?(ctx[:current_field].original_name)` over a literal
    # Array constant folds to that field's answer. A context value a
    # resolver sets (`context[:k] = :read_build` in its `resolve`) is read
    # as each value it may hold: nil, when the query takes no path through
    # that resolver, or each literal some resolver assigns. Which one holds
    # depends on the query, so the field's guard is the conjunction over
    # all of them, a lower bound (docs/adr/0003): the field is certainly
    # readable only where every possible context allows it. A context key
    # no resolver assigns a literal stays as written (opaque, or a `term`).
    class GraphqlFieldClasses
      CONTEXT = /\Acontext\[:(\w+)\]\z/
      FIELD_NAME = /\Acontext\[:current_field\]\.(?:original_name|name)\z/
      RESOLVE = %w[resolve resolve_with_lookahead].freeze

      # Bindings past this many are not enumerated: the field class's
      # check becomes one opaque leaf.
      MAX_BINDINGS = 16

      def initialize(index, translator, policies, aliases:, cleanup:)
        @index = index
        @translator = translator
        @policies = policies
        @aliases = aliases
        @cleanup = cleanup
        @assigned = nil
      end

      # The guard `field` (declared in `call.owner`) gets from its field
      # class, on records of `resource`; nil when its field class adds
      # nothing.
      def guard(call, name, resource)
        method = check_method(call.owner)
        return nil unless method

        params = method.node.parameters&.requireds || []
        record = param(params[0])
        context = param(params[2])
        combos = bindings(method, context)
        return Guard.new(:opaque, "#{method.owner}#authorized?", method.location) if combos.size > MAX_BINDINGS

        aliases = aliases_for(record, context)
        combos.map { |binding| read(method, name, resource, aliases, binding) }
              .reduce { |all, each| Guard.conjoin(all, each) }
      end

      # The `field_class` a class's fields use: its own declaration, else
      # its nearest app ancestor's; nil when none declares one.
      def field_class(name)
        @index.ancestors(name).each do |ancestor|
          call = @index.scopes.fetch(ancestor).calls.find { |found| found.name == :field_class }
          node = call&.arguments&.first
          next unless call && node

          return @index.resolve_constant(node.slice.delete_prefix("::"), ancestor.split("::"))
        end
        nil
      end

      # Literal values resolvers assign to each context key, in `resolve`
      # or `resolve_with_lookahead`; a key also assigned something else is
      # left out.
      def assigned
        @assigned ||= begin
          found = {}
          unread = []
          @index.scopes.each_value do |scope|
            RESOLVE.each do |name|
              method = scope.defs[name]
              assignments(method.node).each { |key, value| record_value(found, unread, key, value) } if method
            end
          end
          found.except(*unread)
        end
      end

      private

      # The `authorized?` that runs for fields declared in `owner`: on its
      # field class or a class between it and the default; nil when the
      # owner uses the default.
      def check_method(owner)
        own = field_class(owner)
        return nil unless own

        base = default_class(owner)
        return nil if base.nil? || base == own

        @index.ancestors(own).each do |ancestor|
          break if ancestor == base

          method = @index.scopes.fetch(ancestor).defs["authorized?"]
          return method if method
        end
        nil
      end

      # The field class above the one `owner` declares: the nearest
      # declaration among the ancestors after the declaring class.
      def default_class(owner)
        chain = @index.ancestors(owner)
        declaring = chain.index do |ancestor|
          @index.scopes.fetch(ancestor).calls.any? { |call| call.name == :field_class }
        end
        rest = declaring ? chain.drop(declaring + 1) : []
        rest.empty? ? nil : field_class(rest.first.to_s)
      end

      def param(node) = node.is_a?(Prism::RequiredParameterNode) ? node.name.to_s : nil

      # The schema's names, with the checked object as the record and the
      # context parameter as `context`.
      def aliases_for(record, context)
        aliases = @aliases.dup
        aliases[record] = Terms::RECORD if record
        aliases[context] = "context" if context
        aliases
      end

      # One Hash per combination of the values of the context keys the
      # body reads that resolvers assign.
      def bindings(method, context)
        keys = context ? read_keys(method.node, context) & assigned.keys : []
        keys.reduce([{}]) do |combos, key|
          combos.flat_map { |combo| [nil, *assigned.fetch(key)].map { |value| combo.merge(key => value) } }
        end
      end

      def read_keys(node, context)
        found = []
        walk(node) do |each|
          receiver = each.receiver
          key = each.arguments&.arguments&.first
          next unless each.name == :[] && receiver.is_a?(Prism::LocalVariableReadNode) &&
                      receiver.name.to_s == context && key.is_a?(Prism::SymbolNode)

          found << key.unescaped
        end
        found.uniq
      end

      def read(method, name, resource, aliases, binding)
        body = method.node.body
        return Guard.new(:never) unless body

        guard = @translator.expression(body, nil, method.owner, resource, aliases: aliases,
                                                                          resolver: resolver(method.owner, name,
                                                                                             resource, binding),
                                                                          file: method.file)
        @cleanup.call(guard)
      end

      def resolver(klass, name, resource, binding)
        lambda do |node, render|
          nil_check(node, render, binding) || bound(node, render, binding) ||
            open_field(node, render, klass, name) || permission(node, render, resource, binding)
        end
      end

      # `ctx[:k].nil?` for a bound key.
      def nil_check(node, render, binding)
        receiver = node.receiver
        return nil unless node.name == :nil? && receiver

        key = render.call(receiver)[CONTEXT, 1]
        return nil unless key && binding.key?(key)

        Guard.new(binding[key].nil? ? :none : :never)
      end

      # `ctx[:k]` read as a condition: its value's truth.
      def bound(node, render, binding)
        key = render.call(node)[CONTEXT, 1]
        return nil unless key && binding.key?(key)

        Guard.new(binding[key] ? :none : :never)
      end

      # `OPEN.include?(ctx[:current_field].original_name)` for this field.
      def open_field(node, render, klass, name)
        receiver = node.receiver
        arg = node.arguments&.arguments&.first
        return nil unless node.name == :include? && arg && render.call(arg).match?(FIELD_NAME)

        names = constant_names(receiver, klass)
        return nil unless names

        Guard.new(names.include?(name) ? :none : :never)
      end

      def constant_names(receiver, klass)
        return nil unless receiver.is_a?(Prism::ConstantReadNode)

        value = @index.constant(klass, receiver.name.to_s)
        value = value.receiver if value.is_a?(Prism::CallNode) && value.name == :freeze
        return nil unless value.is_a?(Prism::ArrayNode)

        names = value.elements.map { |element| literal(element) }
        names.include?(nil) ? nil : names.compact
      end

      # `user.can?(ctx[:k], object)` (or a literal ability): the ability on
      # the record through its policy; nil denies.
      def permission(node, render, resource, binding)
        first = on_record(node, render)
        return nil unless first

        ability = ability_of(first, render, binding)
        return Guard.new(:never) if ability.nil?

        (resource && @policies.ability_guard(resource, ability)) || Guard.new(:opaque, "can?(:#{ability}, record)", nil)
      end

      # The ability argument of `can?(ability, record)`; nil for any other call.
      def on_record(node, render)
        args = node.arguments&.arguments || []
        node.name == :can? && args.size == 2 && render.call(args.fetch(1)) == Terms::RECORD ? args.first : nil
      end

      # A bound context value, else a literal ability.
      def ability_of(node, render, binding)
        key = render.call(node)[CONTEXT, 1]
        key && binding.key?(key) ? binding[key] : literal(node)
      end

      def assignments(node)
        found = []
        walk(node) do |each|
          receiver = each.receiver
          args = each.arguments&.arguments || []
          key = args.first
          next unless each.name == :[]= && args.size == 2 && key.is_a?(Prism::SymbolNode) && context_reader?(receiver)

          found << [key.unescaped, args.fetch(1)]
        end
        found
      end

      def context_reader?(node)
        node.is_a?(Prism::CallNode) && node.name == :context && node.receiver.nil? && node.arguments.nil?
      end

      def record_value(found, unread, key, node)
        value = literal(node)
        if value || node.is_a?(Prism::NilNode)
          (found[key] ||= []) << value unless found.fetch(key, []).include?(value)
        else
          unread << key
        end
      end

      def literal(node)
        case node
        when Prism::SymbolNode, Prism::StringNode then node.unescaped
        end
      end

      def walk(node, &block)
        return unless node.is_a?(Prism::Node)

        yield node if node.is_a?(Prism::CallNode)
        node.compact_child_nodes.each { |child| walk(child, &block) }
      end
    end
  end
end
