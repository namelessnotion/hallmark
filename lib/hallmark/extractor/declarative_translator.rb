# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # Translates a DeclarativePolicy ability into a guard (phase 2 step 4).
    # DeclarativePolicy allows an ability when some `enable` rule for it
    # holds and no `prevent` rule (or `prevent_all`) does; a delegate's rules
    # join in, evaluated on the delegated subject, unless the policy
    # `overrides` the ability. So the guard is the OR of the enabling rules'
    # conditions AND NOT the OR of the preventing ones, delegates included.
    #
    # A rule's condition is read as DeclarativePolicy reads it: `&`, `|`, `~`
    # combine conditions, `can?(:other)` is another ability on the same
    # subject, and a name is a `condition` of the policy (or its ancestors).
    # A condition is the mapping's `term` for its name (`"ProjectPolicy#guest"`
    # or `"guest"`) when there is one, else its block body, translated like a
    # Pundit rule with the subject renamed: `@subject` and readers such as
    # `def project = @subject` read as `record`, or `record.project` inside a
    # delegate, so terms name what the subject is to the checked record.
    #
    # Two DSL hazards are recorded as `lints` while reading (docs/PLAN.md, D3
    # and D4): `&&`, `||` or `!` in a rule block (conditions are objects, so
    # `a && b` is `b`; the guard keeps that meaning), and a condition cached
    # at a scope that leaves out what its body reads (`scope: :user` reading
    # the subject).
    class DeclarativeTranslator
      # One hazard: "D3" or "D4", where, and what.
      # `subject` names what a lint is about when a later stage links it to
      # a check (G5: the GraphQL type whose `scope_items` it concerns).
      Lint = Struct.new(:kind, :location, :message, :subject, keyword_init: true) do
        def to_s = "#{kind} #{location}: #{message}"
      end

      attr_reader :lints

      def initialize(index, terms, methods)
        @index = index
        @terms = terms
        @methods = methods
        @resource = nil
        @memo = {}
        @lints = []
      end

      # The guard for `ability` on `class_name`, checked on a record of
      # `resource`; nil when the class is not a DeclarativePolicy policy.
      def ability(class_name, ability, resource)
        return nil unless @index.declarative?(class_name)

        @resource = resource
        @memo = {}
        evaluate(class_name, ability, "record", [])
      end

      private

      # Where an ability is being read: the policy class, the subject as the
      # checked record names it ("record", or "record.project" inside a
      # delegate), and the abilities being read, for the recursion guard.
      Place = Struct.new(:klass, :subject, :stack, keyword_init: true)

      def evaluate(klass, ability, subject, stack)
        key = "#{klass}|#{ability}|#{subject}"
        return Guard.new(:opaque, "can?(:#{ability})", nil) if stack.include?(key)
        return @memo.fetch(key) if @memo.key?(key)

        enables, prevents = steps(Place.new(klass: klass, subject: subject, stack: stack + [key]), ability)
        @memo[key] = Guard.conjoin(any(enables), Guard.negate(any(prevents)))
      end

      # The conditions of the enabling and the preventing rules, delegates'
      # included.
      def steps(place, ability)
        enables = []
        prevents = []
        @index.dp_rules(place.klass).each do |rule|
          enables << expression(rule.condition, rule, place) if rule.enables.include?(ability)
          prevents << expression(rule.condition, rule, place) if rule.prevent_all || rule.prevents.include?(ability)
        end
        delegated(place, ability, enables, prevents) unless @index.overridden?(place.klass, ability)
        [enables, prevents]
      end

      # A delegate Hallmark cannot follow may prevent anything, so it reads
      # as an opaque prevent: the lower bound then allows nothing.
      def delegated(place, ability, enables, prevents)
        @index.delegates(place.klass).each do |delegate|
          target, path = delegate_target(delegate)
          unless target && path
            prevents << Guard.new(:opaque, "delegate #{delegate.body&.slice}", "#{delegate.file}:#{delegate.line}")
            next
          end

          inner = Place.new(klass: target, subject: "#{place.subject}.#{path}", stack: place.stack)
          more_enables, more_prevents = steps(inner, ability)
          enables.concat(more_enables)
          prevents.concat(more_prevents)
        end
      end

      # `delegate { @subject.project }` delegates to ProjectPolicy on the
      # subject's `project`; so does a helper returning it (GitLab's
      # `subject_container`: `@subject.project || @subject.try(:namespace)`).
      def delegate_target(delegate)
        body = delegate.body
        last = body.is_a?(Prism::StatementsNode) ? body.body.last : body
        name = subject_reader(last) || helper_reader(last, delegate.owner)
        return [nil, nil] unless name

        policy = "#{name.split("_").map(&:capitalize).join}Policy"
        owner = @index.scopes[delegate.owner]
        found = owner ? @index.resolve_constant(policy, owner.namespace) : nil
        [found, name]
      end

      # `x` for `@subject.x`, or the left of `@subject.x || ...`.
      def subject_reader(node)
        node = node.left if node.is_a?(Prism::OrNode)
        return nil unless node.is_a?(Prism::CallNode) && subject?(node.receiver) && node.arguments.nil?

        node.name.to_s
      end

      # The same, through a receiverless helper of the class.
      def helper_reader(node, klass)
        return nil unless node.is_a?(Prism::CallNode) && node.receiver.nil? && node.arguments.nil?

        method = @index.find_method(klass, node.name.to_s)
        body = method&.node&.body
        last = body.is_a?(Prism::StatementsNode) ? body.body.last : body
        subject_reader(last)
      end

      def subject?(node)
        (node.is_a?(Prism::InstanceVariableReadNode) && node.name == :@subject) ||
          (node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :subject)
      end

      def expression(node, rule, place)
        case node
        when Prism::StatementsNode
          node.body.size == 1 ? expression(node.body.first, rule, place) : opaque(node, rule)
        when Prism::ParenthesesNode then expression(node.body, rule, place)
        when Prism::AndNode, Prism::OrNode then boolean(node, rule, place)
        when Prism::CallNode then call(node, rule, place)
        when Prism::TrueNode then Guard.new(:none)
        when Prism::FalseNode, Prism::NilNode then Guard.new(:never)
        when nil then Guard.new(:opaque, "(empty rule)", rule.location)
        else opaque(node, rule)
        end
      end

      # D4: conditions are objects, always truthy, so `a && b` is `b` and
      # `a || b` is `a`.
      def boolean(node, rule, place)
        lint("D4", rule.location, "`#{node.slice}` combines conditions with Ruby's boolean operators; use & or |")
        expression(node.is_a?(Prism::AndNode) ? node.right : node.left, rule, place)
      end

      def call(node, rule, place)
        receiver = node.receiver
        return operator(node, receiver, rule, place) if receiver

        asked = can_query(node)
        return evaluate(place.klass, asked, place.subject, place.stack) if asked
        return condition(node.name.to_s, place.klass, place.subject) if node.arguments.nil? && node.block.nil?

        opaque(node, rule)
      end

      # The ability `can?(:x)` asks about on the same subject.
      def can_query(node)
        args = node.arguments&.arguments || []
        first = args.first
        node.name == :can? && args.size == 1 && first.is_a?(Prism::SymbolNode) ? first.unescaped : nil
      end

      def operator(node, receiver, rule, place)
        args = node.arguments&.arguments || []
        left = -> { expression(receiver, rule, place) }
        right = -> { expression(args.fetch(0), rule, place) }
        case node.name
        when :& then args.size == 1 ? Guard.conjoin(left.call, right.call) : opaque(node, rule)
        when :| then args.size == 1 ? Guard.disjoin(left.call, right.call) : opaque(node, rule)
        when :~ then Guard.negate(left.call)
        when :!
          lint("D4", rule.location, "`#{node.slice}` negates a condition with Ruby's `!`; use ~")
          Guard.new(:never)
        else opaque(node, rule)
        end
      end

      # A condition: the mapping's term for it, else its body read with the
      # subject renamed.
      def condition(name, klass, subject)
        key = "#{klass}|#{name}|#{subject}"
        return @memo.fetch(key) if @memo.key?(key)

        @memo[key] = @terms.lookup("#{klass}##{name}", @resource) || @terms.lookup(name, @resource) ||
                     condition_body(name, klass, subject)
      end

      def condition_body(name, klass, subject)
        found = @index.condition_named(klass, name)
        return builtin(name) unless found

        aliases = subject_aliases(klass, subject)
        check_scope(found, aliases)
        @methods.condition(found.body, found.file, klass, @resource, key: "condition #{name}", aliases: aliases)
      end

      # `@subject`, `subject` and the class's readers of it (`def project =
      # @subject`, `alias_method :pipeline_schedule, :subject`).
      def subject_aliases(klass, subject)
        aliases = { "@subject" => subject, "subject" => subject }
        @index.ancestors(klass).each do |name|
          scope = @index.scopes.fetch(name)
          scope.aliases.each { |reader, target| aliases[reader] ||= subject if target == "subject" }
          scope.defs.each_value do |method|
            aliases[method.name] ||= subject_alias(method.node.body, subject)
          end
        end
        aliases
      end

      # What a reader method stands for: the subject itself (`@subject`), or
      # one of its readers (`@subject.project || ...` is the subject's project).
      def subject_alias(body, subject)
        node = body.is_a?(Prism::StatementsNode) && body.body.size == 1 ? body.body.first : body
        return nil if node.nil?
        return subject if subject?(node)

        reader = subject_reader(node)
        reader ? "#{subject}.#{reader}" : nil
      end

      # D3: `scope: :user` caches one answer per user, so a body that reads
      # the subject reuses the first subject's answer for every other.
      def check_scope(found, aliases)
        excluded = excluded_by(found.scope)
        return if excluded.empty?

        reads = reads(found.body, aliases)
        missed = excluded & reads
        return if missed.empty?

        lint("D3", found.location, "condition `#{found.name}` is cached with scope: :#{found.scope} " \
                                   "but reads the #{missed.join(" and ")}")
      end

      # What a condition cached at a scope may not read.
      def excluded_by(scope)
        case scope
        when "user" then %w[subject]
        when "subject" then %w[user]
        when "global" then %w[user subject]
        else []
        end
      end

      # Which of the user and the subject a body reads.
      def reads(body, aliases)
        found = []
        stack = [body]
        while (node = stack.shift)
          found << "user" if node.is_a?(Prism::InstanceVariableReadNode) && node.name == :@user
          found << "subject" if subject_read?(node, aliases)
          node.compact_child_nodes.each { |child| stack << child }
        end
        found.uniq
      end

      def subject_read?(node, aliases)
        return true if subject?(node)

        node.is_a?(Prism::CallNode) && node.receiver.nil? && node.arguments.nil? && aliases.key?(node.name.to_s) &&
          node.name.to_s != "subject"
      end

      # DeclarativePolicy::Base's own conditions, outside the app: `anonymous`
      # (`@user.nil?`) and `default` (true).
      def builtin(name)
        case name
        when "anonymous" then Guard.new(:not, Guard.new(:logged_in))
        when "default" then Guard.new(:none)
        else Guard.new(:opaque, name, nil)
        end
      end

      def lint(kind, location, message)
        entry = Lint.new(kind: kind, location: location, message: message)
        @lints << entry unless @lints.include?(entry)
      end

      def any(guards) = guards.reduce(Guard.new(:never)) { |left, right| Guard.disjoin(left, right) }

      def opaque(node, rule) = Guard.new(:opaque, node.slice.gsub(/\s+/, " "), rule.location)
    end
  end
end
