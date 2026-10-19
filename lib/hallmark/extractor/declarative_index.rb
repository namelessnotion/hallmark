# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # The DeclarativePolicy half of SourceIndex: conditions, rules, delegates
    # and overrides, and the ability lists rules name.
    class SourceIndex
      # A DeclarativePolicy `condition(:name) { ... }`, with the scope its
      # cache key uses (`scope: :user`, or a preceding `with_options` or
      # `with_scope`; nil when none is given).
      Condition = Struct.new(:name, :body, :scope, :file, :line, :owner, keyword_init: true) do
        def location = "#{file}:#{line}"
      end

      # `rule { condition }.enable :x`, `.prevent :x`, `.prevent_all`, or
      # `.policy do ... end` with those inside. `unknown` marks an ability
      # list Hallmark could not read (a splat of something it cannot
      # evaluate). `lists` holds the `enable` and `prevent` arguments as
      # written, read into `enables` and `prevents` once the whole tree is
      # indexed (helpers may live in files indexed later).
      DpRule = Struct.new(:condition, :enables, :prevents, :prevent_all, :unknown, :lists, :file, :line, :owner,
                          keyword_init: true) do
        def location = "#{file}:#{line}"
      end

      # `delegate { @subject.project }`: the body names the delegated subject.
      Delegate = Struct.new(:body, :file, :line, :owner, keyword_init: true)

      DECLARATIVE_BASE = "DeclarativePolicy::Base"

      # Reading a DeclarativePolicy class body: `macro` hands these calls over.
      DECLARATIONS = %i[condition rule enable prevent prevent_all policy delegate overrides with_options with_scope
                        desc].freeze

      # Whether the class inherits, at some depth, from DeclarativePolicy's base.
      def declarative?(name) = ancestors(name).any? { |ancestor| external_superclass(ancestor) == DECLARATIVE_BASE }

      # The conditions, rules, delegates and overrides of a class and its
      # app ancestors (prepended EE modules included).
      def condition_named(class_name, name)
        ancestors(class_name).each do |ancestor|
          found = @scopes.fetch(ancestor).conditions[name]
          return found if found
        end
        nil
      end

      # Ability lists are read with the helpers `class_name` sees, since a
      # prepended EE module calls helpers its host class includes.
      def dp_rules(class_name)
        ancestors(class_name).flat_map do |name|
          @scopes.fetch(name).dp_rules.each do |rule|
            read_lists(rule, class_name)
          end
        end
      end

      def delegates(class_name) = ancestors(class_name).flat_map { |name| @scopes.fetch(name).delegates }

      def overridden?(class_name, ability)
        ancestors(class_name).any? { |name| @scopes.fetch(name).overrides.include?(ability) }
      end

      private

      def declarative(scope, call, file)
        case call.name
        when :condition then condition(scope, call, file)
        when :with_options, :with_scope then pending_scope(call)
        when :delegate then delegate(scope, call, file)
        when :overrides then scope.overrides.concat((call.arguments&.arguments || []).filter_map { |arg| symbol(arg) })
        when :enable, :prevent, :prevent_all, :policy then dp_rule(scope, call, file)
        end
      end

      # `with_options scope: :user` or `with_scope :user` before a condition.
      def pending_scope(call)
        args = call.arguments&.arguments || []
        @pending_scope = call.name == :with_scope ? symbol(args.first) : symbol(keyword_node(args, :scope))
      end

      def condition(scope, call, file)
        args = call.arguments&.arguments || []
        name = symbol(args.first)
        block = call.block
        return unless name && block.is_a?(Prism::BlockNode)

        given = symbol(keyword_node(args, :scope))
        scope.conditions[name] = Condition.new(name: name, body: block.body, scope: given || @pending_scope,
                                               file: file, line: call.location.start_line, owner: scope.name)
        @pending_scope = nil
      end

      def delegate(scope, call, file)
        block = call.block
        return unless block.is_a?(Prism::BlockNode)

        scope.delegates << Delegate.new(body: block.body, file: file, line: call.location.start_line,
                                        owner: scope.name)
      end

      # The outer call of a rule statement, whose receiver is `rule { ... }`.
      def dp_rule(scope, call, file)
        rule = call.receiver
        return unless rule.is_a?(Prism::CallNode) && rule.name == :rule && rule.receiver.nil?

        block = rule.block
        return unless block.is_a?(Prism::BlockNode)

        entry = DpRule.new(condition: block.body, enables: [], prevents: [], prevent_all: false, unknown: false,
                           lists: [], file: file, line: call.location.start_line, owner: scope.name)
        apply(entry, call)
        scope.dp_rules << entry
      end

      # One `enable`, `prevent` or `prevent_all`, or a `policy` block of them.
      def apply(entry, call)
        case call.name
        when :prevent_all then entry.prevent_all = true
        when :enable, :prevent then entry.lists << [call.name, call.arguments&.arguments || []]
        when :policy
          block = call.block
          body = block.is_a?(Prism::BlockNode) ? block.body : nil
          statements = body.is_a?(Prism::StatementsNode) ? body.body : []
          statements.grep(Prism::CallNode).each { |inner| apply(entry, inner) if inner.receiver.nil? }
        end
      end

      def read_lists(rule, class_name)
        rule.lists.each do |kind, args|
          names = abilities(class_name, args, {})
          rule.unknown = true unless names
          (kind == :enable ? rule.enables : rule.prevents).concat(names || [])
        end
        rule.lists = []
      end

      # Ability names an argument list gives: Symbols, and splats of class
      # methods returning lists such as GitLab's
      # `create_read_update_admin_destroy(:pipeline)`. Nil when any part
      # cannot be read.
      def abilities(owner, args, bindings)
        names = []
        args.each do |arg|
          found = ability_names(owner, arg, bindings)
          return nil unless found

          names.concat(found)
        end
        names
      end

      def ability_names(owner, node, bindings)
        case node
        when Prism::SymbolNode then [node.unescaped]
        when Prism::InterpolatedSymbolNode then interpolated(node, bindings)
        when Prism::SplatNode
          inner = node.expression
          inner ? ability_names(owner, inner, bindings) : nil
        when Prism::ArrayNode then abilities(owner, node.elements, bindings)
        when Prism::ConstantReadNode
          value = constant(owner, node.name.to_s)
          value && ability_names(owner, value, bindings)
        when Prism::CallNode
          receiver = node.receiver
          if node.name == :freeze && receiver
            ability_names(owner, receiver,
                          bindings)
          else
            helper_abilities(owner, node, bindings)
          end
        end
      end

      # `:"read_#{name}"` with `name` bound to a Symbol argument.
      def interpolated(node, bindings)
        text = node.parts.map do |part|
          case part
          when Prism::StringNode then part.unescaped
          when Prism::EmbeddedStatementsNode
            inner = part.statements&.body&.first
            return nil unless inner.is_a?(Prism::LocalVariableReadNode) && bindings.key?(inner.name.to_s)

            bindings.fetch(inner.name.to_s)
          else return nil
          end
        end
        [text.join]
      end

      # A class method of the class or its app ancestors, its parameters
      # bound to Symbol arguments, read for the list it returns.
      def helper_abilities(owner, call, bindings)
        return nil unless call.receiver.nil?

        method = ancestors(owner).lazy.filter_map { |name| @scopes.fetch(name).singletons[call.name.to_s] }.first
        return nil unless method

        bound = bind_symbols(method, call, bindings)
        body = method.body
        last = body.is_a?(Prism::StatementsNode) ? body.body.last : nil
        bound && last ? ability_names(owner, last, bound) : nil
      end

      # The helper's parameters bound to the call's Symbol arguments (or to
      # the caller's own bound parameters); nil when one is anything else.
      def bind_symbols(method, call, bindings)
        params = method.parameters&.requireds || []
        args = call.arguments&.arguments || []
        bound = {}
        params.zip(args).each do |param, arg|
          value = bound_value(arg, bindings)
          return nil unless value && param.is_a?(Prism::RequiredParameterNode)

          bound[param.name.to_s] = value
        end
        bound
      end

      def bound_value(arg, bindings)
        return bindings[arg.name.to_s] if arg.is_a?(Prism::LocalVariableReadNode)

        symbol(arg)
      end
    end
  end
end
