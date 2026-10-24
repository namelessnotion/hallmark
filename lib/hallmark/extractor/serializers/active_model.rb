# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    class Serializers
      # ActiveModel::Serializer's DSL as one class body writes it
      # (Mastodon): `attributes :a, :b` (no conditions), `attribute :x,
      # key:, if:, unless:` with a Symbol (the serializer's own method) or a
      # lambda (instance_exec'd, no parameters), `attribute :x do ... end`
      # (a value block), and `has_many`, `has_one` and `belongs_to` with
      # `serializer:`, `key:`, `if:` and `unless:`.
      class ActiveModel
        ASSOCIATIONS = %i[has_many has_one belongs_to].freeze

        # Applies one class or module body's calls (`scope`) to `shown`,
        # the fields shown so far by key, as Ruby runs them.
        def apply(shown, scope)
          scope.calls.each do |call|
            node = call.node
            case node.name
            when :attributes then Serializers.names(node).each { |name| add(shown, call, name, {}) }
            when :attribute then attribute(shown, call)
            when *ASSOCIATIONS then association(shown, call)
            end
          end
        end

        private

        def attribute(shown, call)
          name = Serializers.names(call.node).first
          add(shown, call, name, Serializers.keywords(call.node)) if name
        end

        def association(shown, call)
          name = Serializers.names(call.node).first
          return unless name

          options = Serializers.keywords(call.node)
          add(shown, call, name, options, association: Serializers.constant_text(options["serializer"]) || "")
        end

        # `association` is the serializer an association names ("" for
        # none), nil for an attribute.
        def add(shown, call, name, options, association: nil)
          key = Serializers.literal_name(options["key"]) || name
          owner = call.owner
          shown[key] = Shown.new(serializer: owner, name: name, key: key, conditions: conditions_of(options, call),
                                 location: call.location, nested: association == "" ? nil : association,
                                 namespace: owner.split("::"), association: !association.nil?)
        end

        def conditions_of(options, call)
          [["if", false], ["unless", true]].filter_map do |key, negated|
            node = options[key]
            node && Condition.new(kind: kind_of(node), node: node, negated: negated, owner: call.owner,
                                  file: call.file)
          end
        end

        # :method (a Symbol naming the serializer's method), :lambda or
        # :opaque.
        def kind_of(node)
          return :method if node.is_a?(Prism::SymbolNode)

          Serializers.lambda_parts(node) ? :lambda : :opaque
        end
      end
    end
  end
end
