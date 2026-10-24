# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    class GrapeEndpoints
      # What one Grape endpoint presents (phase 3 step 8): `present x,
      # with: E, ...` and `present :key, x, with: E`, in the endpoint's
      # block and in the helpers it calls, followed one level down with
      # their parameters bound (trailing keywords bound to an optional
      # last parameter as a Hash, as Ruby does), each with the branches it
      # sits in. A local assigned a Hash is read as that Hash, and `with:
      # cond ? A : B` gives two renderings, one per branch.
      class Presents
        SKIPPED = %w[with].freeze

        # One `present` call: what it presents, its options, the locals in
        # force and where it is.
        Presented = Struct.new(:expression, :options, :locals, :location, keyword_init: true)

        def initialize(endpoints, helpers, api, authorizations)
          @endpoints = endpoints
          @helpers = helpers
          @api = api
          @authorizations = authorizations
          @found = []
        end

        def read(node)
          walk(node, @api.file, [], {}, 0)
          @found
        end

        private

        def walk(node, file, branches, locals, depth)
          case node
          when Prism::StatementsNode, Prism::BeginNode
            Serializers.statements(node.is_a?(Prism::BeginNode) ? node.statements : node).each do |statement|
              walk(statement, file, branches, locals, depth)
              if statement.is_a?(Prism::LocalVariableWriteNode)
                locals[statement.name.to_s] = [statement.value, locals.dup]
              end
            end
          when Prism::IfNode, Prism::UnlessNode then branch(node, file, branches, locals, depth)
          when Prism::ElseNode then walk(node.statements, file, branches, locals, depth)
          when Prism::CallNode then call(node, file, branches, locals, depth)
          when Prism::Node then node.compact_child_nodes.each { |child| walk(child, file, branches, locals, depth) }
          end
        end

        def branch(node, file, branches, locals, depth)
          walk(node.predicate, file, branches, locals, depth)
          negated = node.is_a?(Prism::UnlessNode)
          other = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
          [[node.statements, negated], [other, !negated]].each do |body, polarity|
            walk(body, file, branches + [condition(node.predicate, polarity, file, locals)], locals.dup, depth)
          end
        end

        def condition(node, negated, file, locals)
          Serializers::Branch.new(node: node, negated: negated, definition: nil, klass: @api.name, file: file,
                                  locals: locals.dup)
        end

        def call(node, file, branches, locals, depth)
          if node.name == :present && node.receiver.nil?
            present(node, file, branches, locals)
          elsif (helper = forwarding_helper(node, depth))
            name = node.name.to_s
            walk(helper.body, @endpoints.helper_file(name) || file, branches, bind(helper, node, locals), 1)
          end
          node.compact_child_nodes.each { |child| walk(child, file, branches, locals, depth) }
        end

        # A helper the endpoint block calls that presents something.
        def forwarding_helper(node, depth)
          return nil unless depth.zero? && node.receiver.nil?

          helper = @endpoints.helper(node.name.to_s, @helpers)
          helper && presents?(helper) ? helper : nil
        end

        def presents?(helper) = contains_present?(helper.body)

        def contains_present?(node)
          return false unless node
          return true if node.is_a?(Prism::CallNode) && node.name == :present && node.receiver.nil?

          node.compact_child_nodes.any? { |child| contains_present?(child) }
        end

        # A helper's parameters bound to the call's arguments: positional
        # ones in order, and trailing keywords to an optional last
        # parameter, as a Hash.
        def bind(helper, call, locals)
          params = helper.parameters
          return {} unless params

          args = call.arguments&.arguments || []
          last = args.last
          keywords = last.is_a?(Prism::KeywordHashNode) ? last : nil
          positional = args.grep_v(Prism::KeywordHashNode)
          pairs = parameter_names(params).zip(positional).select { |name, arg| arg && !name.empty? }
          bind_keywords(pairs.to_h { |name, arg| [name, [arg, locals]] }, params, keywords, locals)
        end

        def bind_keywords(bound, params, keywords, locals)
          last = params.optionals.last
          return bound unless keywords && last && params.keywords.empty?

          bound.merge(last.name.to_s => [keywords, locals])
        end

        def parameter_names(params)
          (params.requireds + params.optionals).map do |param|
            named = param.is_a?(Prism::RequiredParameterNode) || param.is_a?(Prism::OptionalParameterNode)
            named ? param.name.to_s : ""
          end
        end

        def present(node, file, branches, locals)
          args = node.arguments&.arguments || []
          positional = args.grep_v(Prism::KeywordHashNode)
          positional = positional.drop(1) if positional.first.is_a?(Prism::SymbolNode)
          expression = positional.first
          return unless expression

          options = positional.drop(1).map { |arg| hash_of(arg, locals) }.reduce({}, :merge)
          options = options.merge(Serializers.keywords(node))
          presented = Presented.new(expression: expression, options: options.except(*SKIPPED), locals: locals,
                                    location: "#{file}:#{node.location.start_line}")
          entities(options["with"], file, locals).each do |entity, extra, unknown|
            @found << rendering(presented, branches + extra, entity, unknown)
          end
        end

        # A Hash literal, or a local (a bound parameter) holding one.
        def hash_of(node, locals)
          if node.is_a?(Prism::LocalVariableReadNode)
            assigned = locals[node.name.to_s]
            return hash_of(assigned[0], assigned[1]) if assigned
          end
          Serializers.pairs(node)
        end

        # [entity as written, branches it adds, why it is unknown] for each
        # entity `with:` names: one constant, or one per side of a ternary.
        def entities(node, file, locals)
          node = locals[node.name.to_s]&.first if node.is_a?(Prism::LocalVariableReadNode)
          if node.is_a?(Prism::IfNode) && node.subsequent.is_a?(Prism::ElseNode)
            sides = [Serializers.statements(node.statements).last,
                     Serializers.statements(node.subsequent&.statements).last]
            return sides.each_with_index.map do |side, at|
              [Serializers.constant_text(side), [condition(node.predicate, at == 1, file, locals)], unknown(side)]
            end
          end
          [[Serializers.constant_text(node), [], unknown(node)]]
        end

        def unknown(node)
          return "no `with:`" if node.nil?

          Serializers.constant_text(node) ? nil : "with: #{node.slice}"
        end

        def rendering(presented, branches, entity, unknown)
          expression = presented.expression
          locals = presented.locals
          source = Canonical.new(locals).render(expression)
          exact = @authorizations.find { |each| each.subject == source }
          Serializers::Rendering.new(
            kind: :grape, serializer: entity, default: false, namespace: @api.namespace, expression: expression,
            source: source, collection: list?(expression), options: presented.options, locals: locals,
            branches: branches, location: presented.location, scope: nil, user_reader: "current_user", model: nil,
            unknown: unknown,
            authorization: exact, candidates: exact ? [] : @authorizations.select { |each| each.via == source }
          )
        end

        def list?(node)
          return true if node.is_a?(Prism::ArrayNode)

          chain_list?(node)
        end

        def chain_list?(node)
          node.is_a?(Prism::CallNode) && (Controllers::LISTS.include?(node.name) ||
                                                                  chain_list?(node.receiver))
        end
      end
    end
  end
end
