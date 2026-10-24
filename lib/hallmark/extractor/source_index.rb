# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # The classes and modules under a source directory, read with Prism and
    # never loaded: each one's methods, superclass, included modules and the
    # declarations the extractor needs: Action Policy's (`alias_rule`,
    # `default_rule`, `pre_check`) and, for controllers, Rails callbacks
    # (`before_action`, `after_action` and their skips) and the constants a
    # class body assigns (`PUBLIC_ACTIONS = %i[show].freeze`). A class
    # reopened in several files is merged. Every receiverless call in a class
    # body is also kept as written (`calls`), for readers of other DSLs such
    # as graphql-ruby's `field`, and class methods are kept beside instance
    # methods as `self.name` (`def self.authorized?` is `"self.authorized?"`).
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

      # A Rails callback declaration. `kind` is :before, :skip_before, :after
      # or :skip_after; `prepend` marks `prepend_before_action`; `only` and
      # `except` are the nodes as written (a Symbol, a list, or a constant),
      # resolved when asked for (`SourceIndex#applies?`).
      Callback = Struct.new(:kind, :names, :only, :except, :prepend, :owner, keyword_init: true)

      # A receiverless call in a class or module body, as written.
      Call = Struct.new(:node, :file, :owner, keyword_init: true) do
        def name = node.name
        def arguments = node.arguments&.arguments || []
        def location = "#{file}:#{node.location.start_line}"
      end

      CALLBACKS = %i[before_action append_before_action prepend_before_action skip_before_action after_action
                     append_after_action prepend_after_action skip_after_action].freeze

      # `attributes` holds the Rails class attributes the class body sets to
      # a literal (`class_attribute :x, default: false`, `self.x = true`, or
      # a class method doing that, such as Gumroad's
      # `allow_anonymous_user_access!`); `singletons` the class methods.
      # DeclarativePolicy declarations (`conditions`, `dp_rules`, `delegates`,
      # `overrides`) and `prepends`, the EE modules `prepend_mod_with` adds,
      # are read by `Declarative`.
      Scope = Struct.new(:name, :superclass, :namespace, :defs, :includes, :aliases, :default_rule, :pre_checks,
                         :skipped_pre_checks, :attributes, :singletons, :callbacks, :constants, :conditions,
                         :dp_rules, :delegates, :overrides, :prepends, :module, :calls, :location, keyword_init: true)

      # The Action Policy base class, outside the app, whose own rules all
      # deny and whose default rule is `manage?`.
      ACTION_POLICY_BASE = "ActionPolicy::Base"

      VISIBILITIES = %i[private protected public].freeze

      attr_reader :root, :scopes

      def initialize(root, dirs)
        @root = root
        @scopes = {}
        @ancestors = {}
        @pending_scope = nil
        dirs.each do |dir|
          Dir.glob(File.join(root, dir, "**", "*.rb")).each { |path| index_file(path) }
        end
        @ancestors.clear
      end

      # Parses one more file into the index, for an index read lazily (the
      # revocation lint's models, `RoleReads`): ancestors are computed again.
      def add_file(path)
        index_file(path)
        @ancestors.clear
      end

      # The class or module's ancestors inside the app, nearest first: the
      # scope itself, its included modules (last included first), then its
      # superclass's. Memoized: the index does not change once built.
      def ancestors(name) = @ancestors[name] ||= collect_ancestors(name, [])

      def collect_ancestors(name, seen)
        scope = @scopes[name]
        return [] if scope.nil? || seen.include?(name)

        seen << name
        modules = scope.includes.reverse.filter_map { |included| resolve_mixin(included, scope) }
        prepended = prepended_modules(scope)
        parent = parent_of(scope)
        [*prepended.flat_map { |mod| collect_ancestors(mod, seen) }, name,
         *modules.flat_map { |mod| collect_ancestors(mod, seen) },
         *(parent ? collect_ancestors(parent, seen) : [])]
      end

      # The modules prepended to a scope that the app defines: EE modules by
      # their full name, `prepend X` resolved as Ruby would.
      def prepended_modules(scope)
        scope.prepends.filter_map { |mod| @scopes.key?(mod) ? mod : resolve_mixin(mod, scope) }
      end

      # A module a class body includes or prepends: as written in the
      # class's namespace, else inside the class itself, where Ruby also
      # looks (`include Team` in `class User` finds `User::Team`).
      def resolve_mixin(name, scope)
        resolve(name, scope.namespace) || (resolve(name, scope.name.split("::")) unless name.start_with?("::"))
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
        names.select { |name| name.end_with?("?") && !name.start_with?("self.") }.uniq.sort
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

      # Classes named `*Policy`; a module such as GitLab's EE::ProjectPolicy is
      # read only through the class it is prepended to.
      def policies = @scopes.select { |name, scope| name.end_with?("Policy") && scope.module != true }.keys.sort

      # A constant as written inside `namespace`, resolved to an indexed scope.
      def resolve_constant(name, namespace) = resolve(name, namespace)

      # The receiverless calls in the class bodies of a class and its app
      # ancestors (prepended modules first, as `ancestors` orders them).
      def calls(class_name) = ancestors(class_name).flat_map { |name| @scopes.fetch(name).calls }

      # Whether the class inherits, at some depth, from `base`, a class
      # outside the app ("GraphQL::Schema").
      def inherits?(class_name, base) = ancestors(class_name).any? { |ancestor| external_superclass(ancestor) == base }

      # Callbacks a class runs, outermost ancestor first, as declared.
      def callbacks(class_name) = ancestors(class_name).reverse.flat_map { |name| @scopes.fetch(name).callbacks }

      # Whether a callback's `only:` and `except:` let it run for `action`.
      def applies?(class_name, callback, action)
        except = names_in(class_name, callback.except)
        return false if except&.include?(action)

        only = names_in(class_name, callback.only)
        only.nil? || only.include?(action)
      end

      # Action names a node lists: a Symbol, an array of them (`.freeze`d or
      # not), or a constant naming one, looked up in the class and its app
      # ancestors. Nil for no node; an empty list for anything unreadable.
      def names_in(class_name, node)
        case node
        when nil then nil
        when Prism::SymbolNode, Prism::StringNode then [node.unescaped]
        when Prism::ArrayNode then node.elements.flat_map { |element| names_in(class_name, element) || [] }
        when Prism::CallNode
          receiver = node.receiver
          node.name == :freeze && receiver ? names_in(class_name, receiver) : []
        when Prism::ConstantReadNode then names_in(class_name, constant(class_name, node.name.to_s)) || []
        else []
        end
      end

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
          scope.location ||= "#{file}:#{node.location.start_line}"
          mark_kind(scope, node)
          body(scope, node.body, file, parts)
        when Prism::Node
          prepend_mod(node, namespace) if node.is_a?(Prism::CallNode)
          node.compact_child_nodes.each { |child| walk(child, namespace, file) }
        end
      end

      # Whether the scope is a class (with its superclass) or a module.
      def mark_kind(scope, node)
        unless node.is_a?(Prism::ClassNode)
          scope.module = true if scope.module.nil?
          return
        end

        scope.module = false
        superclass = node.superclass
        scope.superclass ||= constant_name(superclass, absolute: true) if superclass
      end

      # GitLab's `ProjectPolicy.prepend_mod_with("ProjectPolicy")` (or
      # `prepend_mod`) prepends `EE::ProjectPolicy` when it exists.
      def prepend_mod(call, namespace)
        receiver = call.receiver
        return unless %i[prepend_mod_with prepend_mod].include?(call.name) && receiver && constant?(receiver)

        target = constant_name(receiver)
        named = call.arguments&.arguments&.first
        mod = named.is_a?(Prism::StringNode) ? named.unescaped : target
        scope_for([*namespace, target].join("::"), namespace).prepends << "EE::#{mod}"
      end

      def scope_for(name, namespace)
        @scopes[name] ||= Scope.new(name: name, superclass: nil, namespace: namespace, defs: {}, includes: [],
                                    aliases: {}, default_rule: nil, pre_checks: [], skipped_pre_checks: [],
                                    attributes: {}, singletons: {}, callbacks: [], constants: {}, conditions: {},
                                    dp_rules: [], delegates: [], overrides: [], prepends: [], module: nil,
                                    calls: [], location: nil)
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
            singleton_body(scope, statement.body, file)
          when Prism::CallNode
            visibility = declaration(scope, statement, file, visibility, parts)
          when Prism::AliasMethodNode
            alias_names(scope, symbol(statement.new_name), symbol(statement.old_name))
          when Prism::ConstantWriteNode
            scope.constants[statement.name.to_s] = statement.value
          when Prism::ClassNode, Prism::ModuleNode
            walk(statement, parts, file)
          end
        end
      end

      # A `def self.x` is a class method, kept for `class_method_call`, and
      # as the method `self.x` for translators.
      def define(scope, node, file, visibility)
        name = node.name.to_s
        return define_singleton(scope, node, file) if node.receiver

        scope.defs[name] = Method.new(name: name, node: node, file: file, visibility: visibility, owner: scope.name)
      end

      def define_singleton(scope, node, file)
        name = node.name.to_s
        scope.defs["self.#{name}"] = Method.new(name: "self.#{name}", node: node, file: file, visibility: :public,
                                                owner: scope.name)
        scope.singletons[name] = node
      end

      # Returns the visibility in force after the call: `private` alone
      # changes it, `private def x` and `private :x` change one method's.
      def declaration(scope, call, file, visibility, parts)
        args = call.arguments&.arguments || []
        if !VISIBILITIES.include?(call.name)
          macro(scope, call, args, file, parts)
        elsif args.empty?
          return call.name
        else
          args.each { |arg| visibility_of(scope, arg, file, call.name) }
        end
        visibility
      end

      def macro(scope, call, args, file, parts)
        record_call(scope, call, file)
        case call.name
        when :prepended, :included then body(scope, block_body(call), file, parts) if call.receiver.nil?
        when :class_methods then singleton_body(scope, block_body(call), file)
        when *DECLARATIONS then declarative(scope, call, file)
        when :include, :prepend then mixin(scope, call.name, args)
        when *CALLBACKS then callback(scope, call.name, args)
        else policy_macro(scope, call, args)
        end
      end

      def record_call(scope, call, file)
        scope.calls << Call.new(node: call, file: file, owner: scope.name) if call.receiver.nil?
      end

      # `include X` and `prepend X`, as written.
      def mixin(scope, name, args)
        list = name == :include ? scope.includes : scope.prepends
        args.each { |arg| list << constant_name(arg) if constant?(arg) }
      end

      # Action Policy's declarations, Rails class attributes, and class
      # methods that set them.
      def policy_macro(scope, call, args)
        case call.name
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

      def block_body(call)
        block = call.block
        block.is_a?(Prism::BlockNode) ? block.body : nil
      end

      # `prepend_before_action` is :before with `prepend`; `skip_after_action`
      # is :skip_after.
      def callback(scope, name, args)
        words = name.to_s.delete_suffix("_action").split("_")
        prepend = words.delete("prepend") ? true : false
        words.delete("append")
        kind = words.join("_").to_sym
        names = args.filter_map { |arg| symbol(arg) }
        return if names.empty?

        scope.callbacks << Callback.new(kind: kind, names: names, only: keyword_node(args, :only),
                                        except: keyword_node(args, :except), prepend: prepend, owner: scope.name)
      end

      # A constant's value node, from the class or its nearest app ancestor.
      def constant(class_name, name)
        ancestors(class_name).each do |ancestor|
          found = @scopes.fetch(ancestor).constants[name]
          return found if found
        end
        nil
      end

      def singleton_body(scope, node, file)
        statements = node.is_a?(Prism::StatementsNode) ? node.body : []
        statements.each do |statement|
          define_singleton(scope, statement, file) if statement.is_a?(Prism::DefNode)
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

        parent = parent_of(scope)
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

      # A class's superclass as an indexed scope. Ruby resolves it before the
      # class exists, so `module Admin; class ApplicationController <
      # ApplicationController` names the top-level one, never itself.
      def parent_of(scope)
        superclass = scope.superclass
        return nil unless superclass

        namespace = scope.namespace
        found = resolve(superclass, namespace)
        return found if found && found != scope.name

        if found && !namespace.empty?
          found = resolve(superclass, namespace.take(namespace.size - 1))
          return found if found && found != scope.name
        end
        inherited_constant(scope, superclass)
      end

      # A constant found through the enclosing class's ancestors, as Ruby
      # finds Pundit's `class Scope < Scope` inside `class EventPolicy <
      # ApplicationPolicy`: ApplicationPolicy::Scope.
      def inherited_constant(scope, name)
        enclosing = scope.namespace.join("::")
        return nil if name.start_with?("::") || !@scopes.key?(enclosing)

        ancestors(enclosing).drop(1).each do |ancestor|
          candidate = "#{ancestor}::#{name}"
          return candidate if candidate != scope.name && @scopes.key?(candidate)
        end
        nil
      end

      # The superclass of an indexed class when it lies outside the app.
      def external_superclass(name)
        scope = @scopes.fetch(name)
        superclass = scope.superclass
        return nil if superclass.nil? || parent_of(scope)

        superclass.delete_prefix("::")
      end
    end
  end
end
