# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    class Serializers
      # Grape::Entity's DSL as one class body writes it (GitLab's REST
      # API): `expose :a, :b`, `as:`, `if:` and `unless:` (a lambda or
      # proc, a Symbol naming an option, a Hash of options), `with_options`
      # blocks whose conditions are ANDed with each `expose` inside,
      # `expose :x do ... end` (a value block when it takes parameters, a
      # nesting block of the same record's fields when it takes none, as
      # grape-entity decides by the block's arity), `using:`/`with:` naming
      # a nested entity, `override: true`, `unexpose` and `unexpose_all`.
      # `documentation:`, `format_with`, `expose_nil`, `safe:`, `proc:` and
      # `merge:` change no field's name or condition.
      class GrapeEntity
        # Where a call is read: its file and class body, the conditions of
        # the `with_options` and nesting blocks around it, and the key of
        # the nesting block it is in.
        Place = Struct.new(:file, :scope, :conditions, :prefix, keyword_init: true) do
          def within(conditions: self.conditions, prefix: self.prefix)
            Place.new(file: file, scope: scope, conditions: conditions, prefix: prefix)
          end
        end

        # Applies one class or module body's calls (`scope`) to `shown`,
        # the fields shown so far by key, as Ruby runs them.
        def apply(shown, scope)
          scope.calls.each do |call|
            statement(shown, call.node, Place.new(file: call.file, scope: scope, conditions: [], prefix: nil))
          end
        end

        private

        def statement(shown, node, place)
          return unless node.is_a?(Prism::CallNode) && node.receiver.nil?

          case node.name
          when :expose then expose(shown, node, place)
          when :with_options then with_options(shown, node, place)
          when :unexpose then Serializers.names(node).each { |name| shown.delete(Serializers.join(place.prefix, name)) }
          when :unexpose_all then shown.clear
          end
        end

        def expose(shown, call, place)
          options = Serializers.keywords(call)
          own = place.conditions + conditions_of(options, place)
          names = Serializers.names(call)
          block = call.block
          if block.is_a?(Prism::BlockNode) && block.parameters.nil?
            names.each do |name|
              nest(shown, block, place.within(conditions: own, prefix: path(place, options["as"], name)))
            end
            return
          end

          names.each do |name|
            add(shown, call, place.within(conditions: own), name,
                path(place, names.size == 1 ? options["as"] : nil, name))
          end
        end

        def add(shown, call, place, name, path)
          options = Serializers.keywords(call)
          nested = Serializers.constant_text(options["using"] || options["with"])
          scope = place.scope
          shown[path] = Shown.new(serializer: scope.name, name: name, key: path, conditions: place.conditions,
                                  location: "#{place.file}:#{call.location.start_line}", nested: nested,
                                  namespace: scope.name.split("::"), association: !nested.nil?)
        end

        def path(place, key, name) = Serializers.join(place.prefix, Serializers.literal_name(key) || name)

        # A nesting block's exposes are fields of the same record.
        def nest(shown, block, place)
          Serializers.statements(block.body).each { |each| statement(shown, each, place) }
        end

        def with_options(shown, call, place)
          block = call.block
          return unless block.is_a?(Prism::BlockNode)

          nest(shown, block,
               place.within(conditions: place.conditions + conditions_of(Serializers.keywords(call), place)))
        end

        def conditions_of(options, place)
          [["if", false], ["unless", true]].filter_map do |key, negated|
            node = options[key]
            node && Condition.new(kind: kind_of(node), node: node, negated: negated, owner: place.scope.name,
                                  file: place.file)
          end
        end

        # :lambda, :option (a Symbol: that option is present and truthy),
        # :options (a Hash: each option equals its value) or :opaque.
        def kind_of(node)
          return :lambda if Serializers.lambda_parts(node)
          return :option if node.is_a?(Prism::SymbolNode)
          return :options if node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)

          :opaque
        end
      end
    end
  end
end
