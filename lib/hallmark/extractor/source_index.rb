# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # The classes and modules under a source directory, read with Prism and
    # never loaded: each one's methods, superclass, included modules and the
    # Action Policy declarations the extractor needs (`alias_rule`,
    # `default_rule`, `pre_check`). A class reopened in several files is
    # merged.
    class SourceIndex
      # One `def`, with the file it is in relative to the root.
      Method = Struct.new(:name, :node, :file, :visibility, :owner, keyword_init: true) do
        def line = node.location.start_line
        def location = "#{file}:#{line}"

        # Required positional or keyword parameters: a rule takes none.
        def arity_zero?
          params = node.parameters
          params.nil? || (params.requireds.empty? && params.keywords.none?(Prism::RequiredKeywordParameterNode))
        end
      end

      # `only` and `except` are rule names; nil means no restriction.
      PreCheck = Struct.new(:name, :only, :except, keyword_init: true) do
        def applies?(rule)
          return false if except&.include?(rule)

          list = only
          list.nil? || list.include?(rule)
        end
      end

      # `attributes` holds the Rails class attributes the class body sets to
      # a literal (`class_attribute :x, default: false`, `self.x = true`, or
      # a class method doing that, such as Gumroad's
      # `allow_anonymous_user_access!`); `singletons` the class methods.
      Scope = Struct.new(:name, :superclass, :namespace, :defs, :includes, :aliases, :default_rule, :pre_checks,
                         :skipped_pre_checks, :attributes, :singletons, keyword_init: true)

      # The Action Policy base class, outside the app, whose own rules all
      # deny and whose default rule is `manage?`.
      ACTION_POLICY_BASE = "ActionPolicy::Base"

      VISIBILITIES = %i[private protected public].freeze

      attr_reader :root, :scopes

      def initialize(root, dirs)
        @root = root
        @scopes = {}
        dirs.each do |dir|
          Dir.glob(File.join(root, dir, "**", "*.rb")).each { |path| index_file(path) }
        end
      end

      # The class or module's ancestors inside the app, nearest first: the
      # scope itself, its included modules (last included first), then its
      # superclass's.
      def ancestors(name, seen = [])
        scope = @scopes[name]
        return [] if scope.nil? || seen.include?(name)

        seen << name
        modules = scope.includes.reverse.filter_map { |included| resolve(included, scope.namespace) }
        parent = (superclass = scope.superclass) && resolve(superclass, scope.namespace)
        [name, *modules.flat_map { |mod| ancestors(mod, seen) }, *(parent ? ancestors(parent, seen) : [])]
      end

      # Whether the class inherits, at some depth, from Action Policy's base.
      def action_policy?(name) = ancestors(name).any? { |ancestor| external_superclass(ancestor) == ACTION_POLICY_BASE }

      # The nearest `def name` for a class, following aliases and, after
      # `after` (an ancestor), only further ancestors (for `super`).
      def find_method(class_name, name, after: nil)
        chain = ancestors(class_name)
        chain = chain.drop((chain.index(after) || -1) + 1) if after
        chain.each do |ancestor|
          scope = @scopes.fetch(ancestor)
          found = scope.defs[name]
          return found if found

          target = scope.aliases[name]
          return find_method(class_name, target) if target && target != name
        end
        nil
      end

      # The literal a class attribute holds for a class (its own setting or
      # the nearest ancestor's), or nil when no class body sets it.
      def attribute(class_name, name)
        ancestors(class_name).each do |ancestor|
          scope = @scopes.fetch(ancestor)
          return scope.attributes[name] if scope.attributes.key?(name)
        end
        nil
      end

      # Public rule names a class answers: methods ending in `?` that take
      # no arguments, and aliases, from the class and its app ancestors.
      def rules(class_name)
        names = ancestors(class_name).flat_map do |ancestor|
          scope = @scopes.fetch(ancestor)
          defined = scope.defs.values.select { |method| method.visibility == :public && method.arity_zero? }
          defined.map(&:name) + scope.aliases.keys
        end
        names.select { |name| name.end_with?("?") }.uniq.sort
      end

      # The rule Action Policy falls back to for a rule a policy lacks.
      def default_rule(class_name)
        ancestors(class_name).each do |ancestor|
          rule = @scopes.fetch(ancestor).default_rule
          return rule if rule
        end
        action_policy?(class_name) ? "manage?" : nil
      end

      # Pre-checks that run before `rule`, outermost first.
      def pre_checks(class_name, rule)
        chain = ancestors(class_name).reverse
        skipped = chain.flat_map { |ancestor| @scopes.fetch(ancestor).skipped_pre_checks }
        checks = chain.flat_map { |ancestor| @scopes.fetch(ancestor).pre_checks }
        checks.select do |check|
          check.applies?(rule) && skipped.none? { |skip| skip.name == check.name && skip.applies?(rule) }
        end
      end

      def policies = @scopes.keys.select { |name| name.end_with?("Policy") }.sort

      private

      def index_file(path)
        result = Prism.parse_file(path)
        file = path.delete_prefix("#{@root}/")
        walk(result.value, [], file)
      end

      def walk(node, namespace, file)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          parts = namespace + constant_name(node.constant_path).split("::")
          scope = scope_for(parts.join("::"), namespace)
          if node.is_a?(Prism::ClassNode) && (superclass = node.superclass)
            scope.superclass ||= constant_name(superclass, absolute: true)
          end
          body(scope, node.body, file, parts)
        when Prism::Node
          node.compact_child_nodes.each { |child| walk(child, namespace, file) }
        end
      end

      def scope_for(name, namespace)
        @scopes[name] ||= Scope.new(name: name, superclass: nil, namespace: namespace, defs: {}, includes: [],
                                    aliases: {}, default_rule: nil, pre_checks: [], skipped_pre_checks: [],
                                    attributes: {}, singletons: {})
      end

      # A class or module body: its defs, visibility changes and the
      # declarations the extractor reads; nested classes are walked too.
      def body(scope, node, file, parts)
        statements = node.is_a?(Prism::StatementsNode) ? node.body : []
        visibility = :public
        statements.each do |statement|
          case statement
          when Prism::DefNode
            define(scope, statement, file, visibility)
          when Prism::SingletonClassNode
            singleton_body(scope, statement.body)
          when Prism::CallNode
            visibility = declaration(scope, statement, file, visibility)
          when Prism::AliasMethodNode
            alias_names(scope, symbol(statement.new_name), symbol(statement.old_name))
          when Prism::ClassNode, Prism::ModuleNode
            walk(statement, parts, file)
          end
        end
      end

      # A `def self.x` is a class method, kept for `class_method_call`.
      def define(scope, node, file, visibility)
        name = node.name.to_s
        return scope.singletons[name] = node if node.receiver

        scope.defs[name] = Method.new(name: name, node: node, file: file, visibility: visibility, owner: scope.name)
      end

      # Returns the visibility in force after the call: `private` alone
      # changes it, `private def x` and `private :x` change one method's.
      def declaration(scope, call, file, visibility)
        args = call.arguments&.arguments || []
        if !VISIBILITIES.include?(call.name)
          macro(scope, call, args)
        elsif args.empty?
          return call.name
        else
          args.each { |arg| visibility_of(scope, arg, file, call.name) }
        end
        visibility
      end

      def macro(scope, call, args)
        case call.name
        when :include then args.each { |arg| scope.includes << constant_name(arg) if constant?(arg) }
        when :alias_rule then alias_rule(scope, args)
        when :alias_method then alias_names(scope, symbol(args[0]), symbol(args[1]))
        when :default_rule then scope.default_rule = symbol(args[0])
        when :pre_check, :prepend_pre_check then scope.pre_checks.concat(pre_checks_of(args))
        when :skip_pre_check then scope.skipped_pre_checks.concat(pre_checks_of(args))
        when :class_attribute then class_attribute(scope, args)
        else
          attribute_write(scope, call)
          class_method_call(scope, call)
        end
      end

      def singleton_body(scope, node)
        statements = node.is_a?(Prism::StatementsNode) ? node.body : []
        statements.each do |statement|
          scope.singletons[statement.name.to_s] = statement if statement.is_a?(Prism::DefNode)
        end
      end

      def class_attribute(scope, args)
        default = keyword_node(args, :default)
        return unless default && literal?(default)

        args.each do |arg|
          name = symbol(arg)
          scope.attributes[name] = default if name
        end
      end

      # `self.x = literal` in a class body or a class method's body.
      def attribute_write(scope, call)
        return unless call.receiver.is_a?(Prism::SelfNode) && call.name.end_with?("=")

        value = call.arguments&.arguments&.first
        scope.attributes[call.name.to_s.delete_suffix("=")] = value if value && literal?(value)
      end

      # A bare call in a class body to a class method an ancestor defines,
      # whose body sets class attributes to literals.
      def class_method_call(scope, call)
        return unless call.receiver.nil?

        body = ancestor_singleton(scope, call.name.to_s)&.body
        return unless body.is_a?(Prism::StatementsNode)

        body.body.each { |statement| attribute_write(scope, statement) if statement.is_a?(Prism::CallNode) }
      end

      def ancestor_singleton(scope, name)
        found = scope.singletons[name]
        return found if found

        parent = (superclass = scope.superclass) && resolve(superclass, scope.namespace)
        parent ? ancestor_singleton(@scopes.fetch(parent), name) : nil
      end

      def literal?(node)
        node.is_a?(Prism::TrueNode) || node.is_a?(Prism::FalseNode) || node.is_a?(Prism::NilNode)
      end

      def visibility_of(scope, arg, file, visibility)
        if arg.is_a?(Prism::DefNode)
          define(scope, arg, file, visibility)
        elsif (name = symbol(arg)) && (method = scope.defs[name])
          method.visibility = visibility
        end
      end

      def alias_rule(scope, args)
        target = keyword(args, :to)
        return unless target.is_a?(String)

        args.each { |arg| alias_names(scope, symbol(arg), target) }
      end

      def alias_names(scope, new_name, old_name)
        scope.aliases[new_name] = old_name if new_name && old_name
      end

      def pre_checks_of(args)
        only = keyword(args, :only)
        except = keyword(args, :except)
        args.filter_map do |arg|
          name = symbol(arg)
          name && PreCheck.new(name: name, only: names(only), except: names(except))
        end
      end

      def names(value) = value.nil? ? nil : Array(value)

      # A keyword argument's value: a Symbol's name, a list of them, or nil.
      def keyword(args, key)
        value = keyword_node(args, key)
        return value.elements.filter_map { |element| symbol(element) } if value.is_a?(Prism::ArrayNode)

        symbol(value)
      end

      def keyword_node(args, key)
        hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
        return nil unless hash.is_a?(Prism::KeywordHashNode)

        pair = hash.elements.find { |element| element.is_a?(Prism::AssocNode) && symbol(element.key) == key.to_s }
        pair.is_a?(Prism::AssocNode) ? pair.value : nil
      end

      def symbol(node)
        node.is_a?(Prism::SymbolNode) ? node.unescaped : nil
      end

      def constant?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      # `absolute:` keeps a leading `::`, for constants resolved later.
      def constant_name(node, absolute: false)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode
          name = node.full_name
          absolute ? name : name.delete_prefix("::")
        else node.slice
        end
      end

      # A constant as written inside `namespace`, resolved to an indexed
      # scope the way Ruby looks it up: innermost namespace first, or from
      # the top for `::Name`.
      def resolve(name, namespace)
        if name.start_with?("::")
          top = name.delete_prefix("::")
          return @scopes.key?(top) ? top : nil
        end

        namespace.size.downto(0) do |depth|
          candidate = [*namespace.first(depth), name].join("::")
          return candidate if @scopes.key?(candidate)
        end
        nil
      end

      # The superclass of an indexed class when it lies outside the app.
      def external_superclass(name)
        scope = @scopes.fetch(name)
        superclass = scope.superclass
        return nil if superclass.nil? || resolve(superclass, scope.namespace)

        superclass.delete_prefix("::")
      end
    end
  end
end
