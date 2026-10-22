# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # Translates a Pundit or Action Policy rule's Ruby into a guard over
    # catalog terms. It reads a small subset and is exact on it:
    #
    # - `&&`, `and`, `||`, `or`, `!`, `not`, `if`, `unless`, `else`, `elsif`
    #   and the ternary;
    # - early exits (`return true if ...`, `return false unless ...`,
    #   `raise ...`, and Action Policy's `allow!` and `deny!`), then the last
    #   expression;
    # - `true`, `false` and `nil`;
    # - calls to the policy's other methods (sibling rules, private helpers,
    #   `allowed_to?(:rule?)` and `check?(:rule?)`) and `super`, read in place,
    #   with arguments and blocks bound;
    # - local variables, read as what they were assigned;
    # - comparisons and other expressions the term table names (`Terms`).
    #
    # Anything else becomes an opaque leaf with its source and line, so a
    # translation never guesses (docs/adr/0003). Before the rule run, in
    # order: a constructor's early exits (Gumroad's raises when no user is
    # signed in) and Action Policy's pre-checks.
    #
    # `scope` and `scope_block` read a list scope the same way, with
    # relation chains read as a guard on each record they hold
    # (scope_reader.rb).
    #
    # `expression` reads one condition in controller code the same way, with
    # the controller's names renamed to the policy's (`Canonical`).
    class MethodTranslator
      # Where translation is: the method being read (nil inside a
      # DeclarativePolicy `condition` block), its file, its class (for calls
      # to siblings), the locals in force, and the block it was called with.
      Frame = Struct.new(:definition, :file, :klass, :locals, :block, keyword_init: true)

      # A block passed to a helper: its body and the frame it was written in.
      Block = Struct.new(:body, :frame, keyword_init: true)

      EXITS = %i[allow! deny! raise fail].freeze
      COMPARISONS = %i[== != eql? equal?].freeze
      QUERIES = %i[allowed_to? check?].freeze

      def initialize(index, terms)
        @index = index
        @terms = terms
        @stack = []
        @resource = nil
        @aliases = {}
        @relation = nil
      end

      # The guard for `class_name#rule` checked on a record of `resource`, or
      # nil when the class answers no such rule.
      def rule(class_name, rule, resource)
        @resource = resource
        method = @index.find_method(class_name, rule) || fallback(class_name, rule)
        guard = if method
                  method_guard(method, class_name, {}, nil)
                elsif @index.action_policy?(class_name)
                  never
                else
                  return nil
                end
        guard = wrap_pre_checks(class_name, rule, guard)
        wrap_constructor(class_name, guard)
      end

      # The guard for a condition written in `method` of `class_name`, on a
      # record of `resource`, with `locals` in force and `aliases` renaming
      # the controller's names (`"@product" => "record"`).
      def expression(node, method, class_name, resource, locals: {}, aliases: {})
        @resource = resource
        @aliases = aliases
        enter(method, class_name, locals, nil) { |frame| value(node, frame) }
      ensure
        @aliases = {}
      end

      # The guard for a DeclarativePolicy condition's block body, written in
      # `file` of `class_name`. `key` names the condition for the recursion
      # guard; `aliases` renames the subject (`"@subject" => "record"`, or
      # `"record.project"` inside a delegate).
      def condition(node, file, class_name, resource, key:, aliases:)
        @resource = resource
        @aliases = aliases
        return opaque_named(key, file) if @stack.include?([class_name, key])

        @stack.push([class_name, key])
        frame = Frame.new(definition: nil, file: file, klass: class_name, locals: {}, block: nil)
        sequence(statements(node), frame, nil)
      ensure
        @stack.pop if @stack.last == [class_name, key]
        @aliases = {}
      end

      private

      # An Action Policy rule a policy does not define falls back to its
      # default rule (`manage?` unless `default_rule` names another); with
      # no method for that either, the base class denies (`index?`,
      # `create?`, `new?` and `manage?` return false).
      def fallback(class_name, rule)
        return nil unless @index.action_policy?(class_name)

        default = @index.default_rule(class_name)
        default && default != rule ? @index.find_method(class_name, default) : nil
      end

      def wrap_pre_checks(class_name, rule, guard)
        @index.pre_checks(class_name, rule).reverse.reduce(guard) do |inner, check|
          method = @index.find_method(class_name, check.name)
          method ? body_guard(method, class_name, inner) : Guard.conjoin(opaque_named(check.name), inner)
        end
      end

      def wrap_constructor(class_name, guard)
        method = @index.find_method(class_name, "initialize")
        method ? body_guard(method, class_name, guard) : guard
      end

      # A method read for its exits only: falling off its end continues to
      # `rest`, as a constructor or a pre-check does.
      def body_guard(method, class_name, rest)
        enter(method, class_name, {}, nil) { |frame| sequence(statements(method.node.body), frame, rest) }
      end

      def method_guard(method, class_name, locals, block)
        enter(method, class_name, locals, block) { |frame| sequence(statements(method.node.body), frame, nil) }
      end

      # Guards against recursion: a method already being read is opaque.
      def enter(method, class_name, locals, block)
        key = [method.owner, method.name]
        return opaque_named(method.name, method.location) if @stack.include?(key)

        @stack.push(key)
        begin
          yield Frame.new(definition: method, file: method.file, klass: class_name, locals: locals.dup, block: block)
        ensure
          @stack.pop
        end
      end

      def statements(node)
        case node
        when Prism::StatementsNode then node.body
        when Prism::BeginNode then statements(node.statements)
        when nil then []
        else [node]
        end
      end

      # The value of running `list`. With `rest`, falling off the end
      # continues there (a constructor, a pre-check); without it the last
      # expression is the value, and an empty body returns nil.
      def sequence(list, frame, rest)
        return rest || never if list.empty?

        head = list.fetch(0)
        tail = list.drop(1)
        last = tail.empty? && rest.nil?
        case head
        when Prism::ReturnNode then returned(head, frame)
        when Prism::IfNode, Prism::UnlessNode then conditional(head, tail, frame, rest, last)
        else
          exit = exit_call(head)
          return exit_value(exit) if exit

          last ? value(head, frame) : statement(head, tail, frame, rest)
        end
      end

      # A statement whose value is dropped: an assignment is remembered,
      # anything else is a side effect.
      def statement(node, tail, frame, rest)
        frame.locals[node.name.to_s] = [node.value, frame.locals.dup] if node.is_a?(Prism::LocalVariableWriteNode)
        sequence(tail, frame, rest)
      end

      # A branch that exits, or the last statement, splits the rest; any
      # other `if` is a side effect and is skipped.
      def conditional(node, tail, frame, rest, last)
        then_list, else_list = branches(node)
        return sequence(tail, frame, rest) unless last || exits?(then_list) || exits?(else_list)

        condition = outside_relation { value(node.predicate, frame) }
        condition = Guard.negate(condition) if node.is_a?(Prism::UnlessNode)
        taken = sequence(then_list + tail, frame.dup.tap { |copy| copy.locals = frame.locals.dup }, rest)
        skipped = sequence(else_list + tail, frame.dup.tap { |copy| copy.locals = frame.locals.dup }, rest)
        Guard.disjoin(Guard.conjoin(condition, taken), Guard.conjoin(Guard.negate(condition), skipped))
      end

      def branches(node)
        else_node = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        else_list = case else_node
                    when Prism::ElseNode then statements(else_node.statements)
                    when Prism::IfNode then [else_node]
                    else []
                    end
        [statements(node.statements), else_list]
      end

      def exits?(list)
        list.any? do |statement|
          case statement
          when Prism::ReturnNode then true
          when Prism::IfNode, Prism::UnlessNode then branches(statement).any? { |branch| exits?(branch) }
          else !exit_call(statement).nil?
          end
        end
      end

      # The call when `node` is an exit: `allow!`, `deny!`, `raise` or `fail`.
      def exit_call(node)
        node.is_a?(Prism::CallNode) && node.receiver.nil? && EXITS.include?(node.name) ? node : nil
      end

      def exit_value(node) = node.name == :allow! ? Guard.new(:none) : never

      def returned(node, frame)
        args = node.arguments&.arguments || []
        args.empty? ? never : value(args.fetch(0), frame)
      end

      # The value of an expression; in a list scope, a relation chain reads
      # as the guard on its records (`relation_value`, scope_reader.rb).
      def value(node, frame)
        listed = @relation && relation_value(node, frame)
        return listed if listed

        case node
        when Prism::TrueNode then Guard.new(:none)
        when Prism::FalseNode, Prism::NilNode then never
        when Prism::AndNode then Guard.conjoin(value(node.left, frame), value(node.right, frame))
        when Prism::OrNode then Guard.disjoin(value(node.left, frame), value(node.right, frame))
        when Prism::ParenthesesNode, Prism::StatementsNode, Prism::BeginNode
          sequence(statements(node.is_a?(Prism::ParenthesesNode) ? node.body : node), frame, nil)
        when Prism::IfNode, Prism::UnlessNode then conditional(node, [], frame, nil, true)
        when Prism::ReturnNode then returned(node, frame)
        when Prism::CallNode then call(node, frame)
        when Prism::LocalVariableReadNode then local(node, frame)
        when Prism::LocalVariableWriteNode then value(node.value, frame)
        when Prism::SuperNode, Prism::ForwardingSuperNode then super_call(frame)
        when Prism::YieldNode then yielded(node, frame)
        else term(node, frame)
        end
      end

      def local(node, frame)
        assigned = frame.locals[node.name.to_s]
        return term(node, frame) unless assigned

        value(assigned[0], Frame.new(definition: frame.definition, file: frame.file, klass: frame.klass,
                                     locals: assigned[1], block: frame.block))
      end

      def call(node, frame)
        special = operator(node, frame)
        return special if special

        found = @terms.lookup(render(node, frame), @resource)
        return found if found

        sibling(node, frame) || attribute(node, frame) || term(node, frame)
      end

      # `!`, comparisons, `allow!` and `deny!` as values, and calls of a
      # helper's block.
      def operator(node, frame)
        receiver = node.receiver
        return Guard.negate(value(receiver, frame)) if receiver && node.name == :!
        return comparison(node, frame) if receiver && COMPARISONS.include?(node.name)
        return exit_value(node) if exit_call(node) && %i[allow! deny!].include?(node.name)

        block_call?(node, frame) ? yielded(node, frame) : nil
      end

      # A class attribute the class body sets to a literal.
      def attribute(node, frame)
        receiver = node.receiver
        return nil unless (receiver.nil? || receiver.is_a?(Prism::SelfNode)) && node.arguments.nil?

        literal = @index.attribute(frame.klass, node.name.to_s)
        literal ? value(literal, frame) : nil
      end

      def comparison(node, frame)
        receiver = node.receiver
        args = node.arguments&.arguments || []
        return term(node, frame) unless receiver && args.size == 1

        found = @terms.compare(render(receiver, frame), render(args.fetch(0), frame), @resource)
        return opaque(node, frame) unless found

        node.name == :!= ? Guard.negate(found) : found
      end

      # A call to a method of the policy itself: read in place.
      def sibling(node, frame)
        receiver = node.receiver
        return nil unless receiver.nil? || receiver.is_a?(Prism::SelfNode)

        return query(node, frame) if QUERIES.include?(node.name)

        method = @index.find_method(frame.klass, node.name.to_s)
        return nil unless method

        method_guard(method, frame.klass, bind(method, node, frame), block_of(node, frame))
      end

      # `allowed_to?(:rule?)` on the same record: that rule, without its
      # pre-checks, which already ran.
      def query(node, frame)
        name = symbol_argument(node)
        return nil unless name

        method = @index.find_method(frame.klass, name) || fallback(frame.klass, name)
        return method_guard(method, frame.klass, {}, nil) if method

        @index.action_policy?(frame.klass) ? never : nil
      end

      # The rule a query names, when it names one and passes no record.
      def symbol_argument(node)
        args = node.arguments&.arguments || []
        first = args.first
        args.size == 1 && first.is_a?(Prism::SymbolNode) ? first.unescaped : nil
      end

      # Positional parameters bound to the call's arguments.
      def bind(method, node, frame)
        params = method.node.parameters
        return {} unless params

        args = node.arguments&.arguments || []
        params.requireds.zip(args).each_with_object({}) do |(param, arg), locals|
          next unless param.is_a?(Prism::RequiredParameterNode) && arg

          locals[param.name.to_s] = [arg, frame.locals.dup]
        end
      end

      def block_of(node, frame)
        block = node.block
        return nil unless block.is_a?(Prism::BlockNode)

        Block.new(body: block.body, frame: frame)
      end

      # `block.call` or `yield` inside a helper called with a block.
      def block_call?(node, frame)
        receiver = node.receiver
        return false unless node.name == :call && receiver.is_a?(Prism::LocalVariableReadNode)

        definition = frame.definition
        param = definition ? definition.node.parameters&.block : nil
        !param.nil? && param.name.to_s == receiver.name.to_s && !frame.block.nil?
      end

      def yielded(node, frame)
        block = frame.block
        return opaque(node, frame) unless block

        sequence(statements(block.body), block.frame, nil)
      end

      def super_call(frame)
        method = frame.definition
        return opaque_named("super", frame.file) unless method

        parent = @index.find_method(frame.klass, method.name, after: method.owner)
        return opaque_named("super", method.location) unless parent

        method_guard(parent, frame.klass, frame.locals, frame.block)
      end

      def term(node, frame) = @terms.lookup(render(node, frame), @resource) || opaque(node, frame)

      def render(node, frame) = Canonical.new(frame.locals, @aliases).render(node)

      def opaque(node, frame)
        Guard.new(:opaque, render(node, frame), "#{frame.file}:#{node.location.start_line}")
      end

      def opaque_named(name, location = nil) = Guard.new(:opaque, name, location)

      def never = Guard.new(:never)
    end
  end
end
