# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # List scopes (phase 3 step 7): the translator reads a scope's body as a
    # guard on one record of the list it returns, so the list may contain a
    # record wherever the guard holds. The body is read as a rule's is
    # (branches, early exits, locals, helpers and `super`), and wherever a
    # value is a relation chain it reads the chain:
    #
    # - the root (`scope` or `@scope` in a Pundit scope, the block's
    #   relation in Action Policy, graphql-ruby's items, the resource's
    #   class) and `all`: every record, `none`: none;
    # - `where(attr: value)`, each pair the term for `record.attr == value`
    #   (ownership, the current tenant), `where(published: true)` the term
    #   for `record.published?` (`public_if:`), and the record's tenant among
    #   the user's (`where(organization: user.organizations)`,
    #   `organization_id: user.organization_ids`) membership of the
    #   record's tenant (`member`); `where.not(...)` the negation;
    # - `or` and `merge` as OR and AND, `select { |r| ... }` through the
    #   translator, an association named after the resource on an object
    #   (`user.links`, `seller.links`) as the record's owner or tenant being
    #   that object;
    # - ordering, eager loading and pagination change no membership: any
    #   record the filter keeps can be on some page.
    #
    # A `term` for the chain (or any part of it) as written with the root
    # read as `scope` wins (`term "scope.published", public_record`).
    # Anything else (joins, SQL strings, Arel, the app's own scopes) is an
    # opaque leaf ANDed in, bounded as docs/adr/0003 says.
    class MethodTranslator
      # Calls that keep every record the receiver holds.
      KEEPING = %i[all distinct order reorder includes preload eager_load references limit offset page per readonly
                   strict_loading to_a load records].freeze

      # What a relation starts from: names read as the whole list (a reader
      # such as `scope`, a block parameter, an instance variable such as
      # `@scope`) and the resource's class.
      Relation = Struct.new(:roots, :model, keyword_init: true)

      # The guard on one record of the list `method` (Pundit's
      # `Scope#resolve`, graphql-ruby's `self.scope_items`) returns, on
      # records of `resource`. `roots` name the relation it starts from.
      def scope(method, class_name, resource, roots:, aliases: {})
        @resource = resource
        @aliases = aliases
        guard = within_relation(roots) do
          enter(method, class_name, {}, nil) { |frame| sequence(statements(method.node.body), frame, nil) }
        end
        # A constructor's exits (Forem's raises unless a user is signed in).
        method.name.start_with?("self.") ? guard : wrap_constructor(class_name, guard)
      ensure
        @aliases = {}
      end

      # The same for a block body written in `class_name`'s body (Action
      # Policy's `relation_scope { |relation| ... }`).
      def scope_block(body, file, class_name, resource, roots:)
        @resource = resource
        frame = Frame.new(definition: nil, file: file, klass: class_name, locals: {}, block: nil)
        within_relation(roots) { sequence(statements(body), frame, nil) }
      end

      private

      def within_relation(roots)
        outer = @relation
        @relation = Relation.new(roots: roots, model: @resource)
        yield
      ensure
        @relation = outer
      end

      # A condition is never a relation: `if scope.exists?` reads as a call.
      def outside_relation
        outer = @relation
        @relation = nil
        yield
      ensure
        @relation = outer
      end

      # The guard of a relation expression, or nil when `node` is not one.
      # A local holding a relation reads as what was assigned to it.
      def relation_value(node, frame)
        relation = @relation
        return nil unless relation && relational?(node, frame, relation)

        if node.is_a?(Prism::LocalVariableReadNode) && (assigned = frame.locals[node.name.to_s])
          return relation_value(assigned[0], Frame.new(definition: frame.definition, file: frame.file,
                                                       klass: frame.klass, locals: assigned[1], block: frame.block))
        end

        written = @terms.lookup(scope_source(node, frame, relation), @resource)
        return written if written

        node.is_a?(Prism::CallNode) ? chain(node, frame, relation) : Guard.new(:none)
      end

      # Whether the expression starts from the relation: a root, the
      # resource's class, an association named after the resource, or a
      # local assigned one of those.
      def relational?(node, frame, relation)
        case node
        when Prism::LocalVariableReadNode
          name = node.name.to_s
          assigned = frame.locals[name]
          assigned ? relational?(assigned[0], frame, relation) : relation.roots.include?(name)
        when Prism::InstanceVariableReadNode then relation.roots.include?(node.name.to_s)
        when Prism::ConstantReadNode, Prism::ConstantPathNode then model?(node, relation)
        when Prism::CallNode
          receiver = node.receiver
          return root_call?(node, relation) || association?(node) unless receiver

          relational?(receiver, frame, relation) || association?(node)
        else false
        end
      end

      def root_call?(node, relation)
        node.arguments.nil? && node.block.nil? && relation.roots.include?(node.name.to_s)
      end

      def model?(node, relation)
        model = relation.model
        !model.nil? && node.slice.delete_prefix("::") == model
      end

      # `user.links` for a Link: the records an object holds through an
      # association named after the resource.
      def association?(node)
        resource = @resource
        !node.receiver.nil? && node.arguments.nil? && !resource.nil? &&
          node.name.to_s == Naming.plural(resource)
      end

      def chain(node, frame, relation)
        receiver = node.receiver
        # A root reader such as `scope`.
        return Guard.new(:none) unless receiver
        return holder(node, receiver, frame) unless relational?(receiver, frame, relation)

        base = relation_value(receiver, frame) || Guard.new(:none)
        case node.name
        when *KEEPING then base
        when :none then Guard.new(:never)
        when :where then node.arguments.nil? ? base : Guard.conjoin(base, pairs(node, frame))
        when :not then negated(node, frame)
        when :or then Guard.disjoin(base, argument_relation(node, frame))
        when :merge then Guard.conjoin(base, argument_relation(node, frame))
        when :select, :filter then Guard.conjoin(base, selected(node, frame))
        else Guard.conjoin(base, step_term(node, receiver, frame, relation) || opaque(node, frame))
        end
      end

      # A step of the chain as a `term` names it, on the root: the app's
      # own scope `published` in `relation.where(...).published` is
      # `term "scope.published", public_record`.
      def step_term(node, receiver, frame, relation)
        whole = scope_source(node, frame, relation)
        start = scope_source(receiver, frame, relation)
        whole.start_with?(start) ? @terms.lookup("scope#{whole.delete_prefix(start)}", @resource) : nil
      end

      # `where.not(...)`: the receiver of `where`, without the pairs.
      def negated(node, frame)
        where = node.receiver
        inner = where.is_a?(Prism::CallNode) && where.name == :where && where.arguments.nil? ? where.receiver : nil
        return opaque(node, frame) unless inner

        base = relation_value(inner, frame) || Guard.new(:none)
        Guard.conjoin(base, Guard.negate(pairs(node, frame)))
      end

      def argument_relation(node, frame)
        arg = node.arguments&.arguments&.first
        (arg && relation_value(arg, frame)) || opaque(node, frame)
      end

      # `user.links`: records whose owner, or tenant, is that object.
      def holder(node, receiver, frame)
        resource = @resource
        return opaque(node, frame) unless resource

        found = @terms.holder(render(receiver, frame), resource)
        found || opaque(node, frame)
      end

      # Each pair of a `where`, ANDed: a term, a flag-like attribute, or
      # the record's tenant among the user's.
      def pairs(node, frame)
        hash = node.arguments&.arguments&.first
        return opaque(node, frame) unless hash.is_a?(Prism::KeywordHashNode) || hash.is_a?(Prism::HashNode)

        hash.elements.reduce(Guard.new(:none)) do |all, pair|
          Guard.conjoin(all, pair_guard(pair, frame) || opaque(pair, frame))
        end
      end

      def pair_guard(pair, frame)
        return nil unless pair.is_a?(Prism::AssocNode) && (key = pair.key).is_a?(Prism::SymbolNode)

        name = key.unescaped
        resource = @resource
        case (value = pair.value)
        when Prism::TrueNode then attribute_term(name, resource)
        when Prism::FalseNode then attribute_term(name, resource)&.then { |found| Guard.negate(found) }
        else
          source = render(value, frame)
          @terms.compare("record.#{name}", source, resource) || @terms.membership(name, source, resource)
        end
      end

      def attribute_term(name, resource)
        @terms.lookup("record.#{name}?", resource) || @terms.lookup("record.#{name}", resource)
      end

      # `select { |record| ... }` through the translator, the block's
      # parameter read as the record.
      def selected(node, frame)
        block = node.block
        param = block.is_a?(Prism::BlockNode) ? block_parameter(block) : nil
        return opaque(node, frame) unless block.is_a?(Prism::BlockNode) && param

        outer = @aliases
        @aliases = outer.merge(param => "record")
        begin
          outside_relation { sequence(statements(block.body), frame, nil) }
        ensure
          @aliases = outer
        end
      end

      def block_parameter(block)
        params = block.parameters
        list = params.is_a?(Prism::BlockParametersNode) ? params.parameters : nil
        first = list&.requireds&.first
        first.is_a?(Prism::RequiredParameterNode) ? first.name.to_s : nil
      end

      # The chain as a `term` names it: the root, whatever it is called
      # here, read as `scope`.
      def scope_source(node, frame, relation)
        roots = relation.roots.to_h { |root| [root, "scope"] }
        model = relation.model
        roots[model] = "scope" if model
        Canonical.new(frame.locals, @aliases.merge(roots)).render(node)
      end
    end
  end
end
