# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    class Serializers
      # A field's condition as a guard, for one rendering (phase 3 step 8):
      # a lambda or a serializer method through the method translator,
      # with the serializer's class as the class, the record and the
      # serialization scope renamed to the policies' names, and a resolver
      # answering, before the term table, reads of the options the
      # rendering passes (`options[:k]`, `instance_options[:k]`), their
      # comparisons, and authorization calls on the record; Grape's Symbol
      # and Hash conditions as options. With no rendering, options stay
      # opaque, as written.
      class Conditions
        OPTION = /\A(?:instance_)?options\[:(\w+)\]\z/
        PARAMS = /\A(?:params|declared_params|declared\(params\))\[/

        def initialize(mapping, index, translator, terms:, policies:)
          @mapping = mapping
          @index = index
          @translator = translator
          @terms = terms
          @policies = policies
          @user = mapping.principal_source.is_a?(Symbol) ? mapping.principal_source.to_s : "user"
        end

        # One condition's guard, negated for `unless:`.
        def guard(condition, context)
          guard = case condition.kind
                  when :lambda then lambda_guard(condition, context)
                  when :method then method_guard(condition, context)
                  when :option then option_value(Serializers.literal_name(condition.node).to_s, context)
                  when :options then hash_guard(condition.node, context)
                  else written(condition, context)
                  end
          condition.negated ? Guard.negate(guard) : guard
        end

        private

        # A lambda's first parameter is the record, its second the options;
        # grape-entity and AMS instance_exec it on the serializer, so bare
        # calls are the serializer's methods.
        def lambda_guard(condition, context)
          params, body = Serializers.lambda_parts(condition.node)
          return Guard.new(:never) unless body

          aliases = base_aliases(context)
          record, options = params
          aliases[record] = Terms::RECORD if record && !record.start_with?("_")
          aliases[options] = "options" if options && !options.start_with?("_")
          @translator.expression(body, nil, context.serializer, context.resource, aliases: aliases,
                                                                                  resolver: resolver(context),
                                                                                  file: condition.file)
        end

        # An AMS Symbol: the serializer's method, read in place.
        def method_guard(condition, context)
          name = Serializers.literal_name(condition.node).to_s
          method = @index.find_method(context.serializer, name)
          return opaque(condition.node, condition.file) unless method

          body = method.node.body
          return Guard.new(:never) unless body

          @translator.expression(body, method, context.serializer, context.resource,
                                 aliases: base_aliases(context), resolver: resolver(context))
        end

        # A condition that is neither a lambda nor a name (GitLab's
        # class-level `if: can_read(attr)`): a `term` can name it.
        def written(condition, context)
          node = condition.node
          @terms.lookup(Terms.normalize(node.slice), context.resource) || opaque(node, condition.file)
        end

        # `if: { type: :full }`: each option equals its value.
        def hash_guard(node, context)
          Serializers.pairs(node).reduce(Guard.new(:none)) do |all, (key, value)|
            Guard.conjoin(all, option_equals(key, value, context))
          end
        end

        # The record and the serialization scope as the policies name them,
        # and each option holding the signed-in user as the user.
        def base_aliases(context)
          rendering = context.rendering
          aliases = record_readers(context.serializer).to_h { |name| [name, Terms::RECORD] }
          return default_aliases(aliases) unless rendering

          scope = rendering.scope
          if scope && scope == rendering.user_reader
            aliases["scope"] = @user
            aliases[scope] = @user
          end
          rendering.options.each do |key, node|
            next unless user?(node, rendering)

            aliases["options[:#{key}]"] = @user
            aliases["instance_options[:#{key}]"] = @user
          end
          aliases
        end

        # `object` and the serializer's own names for it: GitLab's
        # `alias_method :project, :object`, or a reader whose body is
        # `object`.
        def record_readers(serializer)
          found = ["object"]
          @index.ancestors(serializer).each do |ancestor|
            scope = @index.scopes.fetch(ancestor)
            found.concat(scope.aliases.select { |_, target| target == "object" }.keys)
            found.concat(scope.defs.values.select { |method| reads_object?(method) }.map(&:name))
          end
          found.uniq
        end

        def reads_object?(method)
          body = method.node.body
          statement = body.is_a?(Prism::StatementsNode) && body.body.size == 1 ? body.body.first : nil
          method.arity_zero? && statement.is_a?(Prism::CallNode) && statement.name == :object &&
            statement.receiver.nil? && statement.arguments.nil?
        end

        # With no rendering, AMS's default scope, `current_user`, is the
        # signed-in user when the controllers' reader has that name.
        def default_aliases(aliases)
          return aliases unless @mapping.principal_controller == "current_user"

          aliases.merge("scope" => @user, "current_user" => @user)
        end

        # Answers option reads, comparisons with options and authorization
        # calls on the record before the term table.
        def resolver(context)
          lambda do |node, render|
            text = render.call(node)
            key = text[OPTION, 1]
            next option_value(key, context) if key && context.rendering

            comparison(node, render, context) || authorization(node, render, context)
          end
        end

        # `options[:k] == value` (or `!=`).
        def comparison(node, render, context)
          args = node.arguments&.arguments || []
          key = compared_option(node, render, args)
          return nil unless key && context.rendering

          found = option_equals(key, args.fetch(0), context)
          node.name == :!= ? Guard.negate(found) : found
        end

        def compared_option(node, render, args)
          receiver = node.receiver
          return nil unless receiver && %i[== !=].include?(node.name) && args.size == 1

          render.call(receiver)[OPTION, 1]
        end

        # The guard an option stands for when read as a condition: the
        # signed-in user is signed in, a parameter is whatever the client
        # asks (true), a literal is itself, an ability on the rendered
        # record is that ability, and an option not passed is nil (false).
        def option_value(key, context)
          rendering = context.rendering
          return Guard.new(:opaque, "options[:#{key}]", nil) unless rendering

          node = rendering.options[key]
          return Guard.new(:never) unless node
          return Guard.new(:logged_in) if user?(node, rendering)

          literal = literal_value(node)
          return literal if literal
          return Guard.new(:none) if params?(node, rendering)

          option_authorization(node, context) || option_opaque(node, rendering)
        end

        def option_equals(key, value, context)
          rendering = context.rendering
          return Guard.new(:opaque, "options[:#{key}] == #{value.slice}", nil) unless rendering

          node = rendering.options[key]
          return value.is_a?(Prism::NilNode) ? Guard.new(:none) : Guard.new(:never) unless node
          return Guard.new(:none) if params?(node, rendering)
          return Guard.new(node.slice == value.slice ? :none : :never) if literal_value(node) && literal_value(value)

          option_opaque(node, rendering)
        end

        # An option Hallmark cannot read, at the rendering that passes it.
        def option_opaque(node, rendering) = Guard.new(:opaque, render(node, rendering), rendering.location)

        def literal_value(node)
          case node
          when Prism::TrueNode, Prism::SymbolNode, Prism::StringNode, Prism::IntegerNode then Guard.new(:none)
          when Prism::FalseNode, Prism::NilNode then Guard.new(:never)
          end
        end

        def user?(node, rendering)
          node.is_a?(Prism::CallNode) && node.receiver.nil? && node.arguments.nil? &&
            node.name.to_s == rendering.user_reader
        end

        def params?(node, rendering) = render(node, rendering).match?(PARAMS)

        def render(node, rendering) = Canonical.new(rendering.locals).render(node)

        # An option the entry point computed with an ability check on the
        # rendered record (`user_can_admin_project: can?(current_user,
        # :admin_project, project)`).
        def option_authorization(node, context)
          rendering = context.rendering
          return nil unless rendering && node.is_a?(Prism::CallNode)

          ability = ability_call(node)
          resource = context.resource
          return nil unless ability && resource && on_rendered?(node, rendering)

          @policies.ability_guard(resource, ability)
        end

        # An ability call for the signed-in user on the rendered record.
        def on_rendered?(node, rendering)
          args = node.arguments&.arguments || []
          user?(args.fetch(0), rendering) && render(args.fetch(2), rendering) == rendering.source
        end

        # `can?(user, :a, x)` or `Ability.allowed?(user, :a, x)`: the ability.
        def ability_call(node)
          args = node.arguments&.arguments || []
          return nil unless args.size == 3

          ability_named?(node) ? Serializers.literal_name(args.fetch(1)) : nil
        end

        def ability_named?(node)
          receiver = node.receiver
          return receiver.nil? if node.name == :can?

          node.name == :allowed? && receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :Ability
        end

        # An authorization call on the record in a condition: a
        # DeclarativePolicy ability for the signed-in user (or for nobody,
        # through an option not passed), or a Pundit or Action Policy rule.
        def authorization(node, render, context)
          resource = context.resource
          return nil unless resource

          rule = rule_call(node, render)
          return rule && @policies.rule_guard(resource, rule) if rule || !ability_call(node)

          ability_guard(node, render, context, resource)
        end

        def ability_guard(node, render, context, resource)
          args = node.arguments&.arguments || []
          return nil unless render.call(args.fetch(2)) == Terms::RECORD

          user = render.call(args.fetch(0))
          anonymous = unpassed?(user, context.rendering)
          return nil unless user == @user || anonymous

          guard = @policies.ability_guard(resource, ability_call(node).to_s)
          guard && anonymous ? Guard.conjoin(Guard.negate(Guard.new(:logged_in)), guard) : guard
        end

        # An option read the rendering does not pass: nil, so nobody.
        def unpassed?(text, rendering)
          key = text[OPTION, 1]
          !rendering.nil? && !key.nil? && !rendering.options.key?(key)
        end

        # `policy(record).show?` or `allowed_to?(:show?, record)`: the rule.
        def rule_call(node, render)
          receiver = node.receiver
          return policy_rule(node, receiver, render) if receiver.is_a?(Prism::CallNode) && receiver.name == :policy

          node.name == :allowed_to? && receiver.nil? ? allowed_to_rule(node, render) : nil
        end

        def allowed_to_rule(node, render)
          args = node.arguments&.arguments || []
          return nil unless args.size == 2

          render.call(args.fetch(1)) == Terms::RECORD ? Serializers.literal_name(args.fetch(0)) : nil
        end

        def policy_rule(node, receiver, render)
          target = receiver.arguments&.arguments&.first
          receiver.receiver.nil? && target && render.call(target) == Terms::RECORD ? node.name.to_s : nil
        end

        def opaque(node, file)
          Guard.new(:opaque, Canonical.new({}).render(node), "#{file}:#{node.location.start_line}")
        end
      end
    end
  end
end
