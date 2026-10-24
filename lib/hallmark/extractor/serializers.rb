# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # What a REST response shows, field by field (phase 3 step 8, threat
    # 4), read from source with Prism and never loaded: Grape::Entity
    # classes (GitLab's REST API) and ActiveModel::Serializer classes
    # (Mastodon), on a `SourceIndex` of their own over the directories
    # that hold them. An entity is a class whose ancestors (prepended EE
    # modules included) reach Grape::Entity, a serializer one that reaches
    # ActiveModel::Serializer. Inheritance is Ruby's: a subclass shows its
    # parent's fields and its own, `unexpose` removes one, and an EE
    # module's `prepended do` block adds its own.
    #
    # Each field's condition is read per rendering (`fields`), since what
    # the entry point passes as options decides it: through the method
    # translator, with the serializer's class as the class (its methods
    # read in place), the lambda's parameters and `object` read as the
    # record, the options table (`Rendering#options`) for `options[:k]`
    # and `instance_options[:k]`, and authorization calls on the record
    # (`Ability.allowed?`, `can?`, `policy(record).rule?`, `allowed_to?`)
    # through the policies. Anything else is an opaque leaf
    # (docs/adr/0003), which a `term` can name.
    #
    # Renderings (how an entry point shows a serializer) are read where
    # its authorize calls are: `Controllers` for `render json:`, and
    # `GrapeEndpoints` for `present ..., with:`.
    class Serializers
      DIRS = %w[lib/api app/api ee/lib/ee/api ee/lib/api app/serializers ee/app/serializers app/entities].freeze
      GRAPE = "Grape::Entity"
      AMS = "ActiveModel::Serializer"
      JBUILDER = "app/views/**/*.json.jbuilder"

      # A condition on a field as written: `kind` is :lambda, :option (a
      # Grape Symbol), :options (a Grape Hash), :method (an AMS Symbol) or
      # :opaque; `negated` for `unless:`.
      Condition = Struct.new(:kind, :node, :negated, :owner, :file, keyword_init: true)

      # One field a serializer shows, as written: its Ruby name, its JSON
      # key, its conditions (ANDed), where it is written, and for an
      # association (`using:`, `serializer:`, `has_many`) the serializer
      # it names as written (nil when it names none), resolved in
      # `namespace`.
      Shown = Struct.new(:serializer, :name, :key, :conditions, :location, :nested, :namespace, :association,
                         keyword_init: true)

      # One field as one rendering shows it: `condition` is its guard
      # (with opaque leaves), and `resource` is set when the field is a
      # record of another mapped resource (a nested record, not a field).
      Field = Struct.new(:serializer, :name, :key, :condition, :location, :resource, keyword_init: true) do
        def nested? = !resource.nil?
        def shown_by = "#{serializer}##{name} (#{location})"
      end

      # How an entry point shows a serializer: `kind` :rails or :grape;
      # `serializer` as written (nil when no `serializer:` or `with:` is
      # given; `default` then says the model's own serializer applies);
      # the rendered expression and its source; whether it is a
      # collection; the options as written (`options[:k]`), with `locals`
      # binding a helper's parameters; the branches it sits in; the
      # serialization scope reader (AMS; nil after `serialization_scope
      # nil`) and the signed-in user's reader; the model class a Rails
      # load names; the authorize call whose record it is (`candidates`
      # are Grape checks made inside the helper that returns it, which
      # count when their resource is the serializer's); and `unknown`, why
      # its serializer cannot be told.
      Rendering = Struct.new(:kind, :serializer, :default, :namespace, :expression, :source, :collection, :options,
                             :locals, :branches, :location, :scope, :user_reader, :model, :authorization,
                             :candidates, :unknown, keyword_init: true) do
        # The rendered expression as written.
        def text = expression.slice
      end

      # A branch a rendering sits in: it runs where `node` holds (fails to,
      # when `negated`), written in `definition` (nil in a Grape endpoint
      # block) of `klass`, with `locals` in force.
      Branch = Struct.new(:node, :negated, :definition, :klass, :file, :locals, keyword_init: true)

      # What a field's condition reads in one rendering of `serializer`,
      # the class whose instance runs it (a lambda is instance_exec'd on
      # it, a Symbol names its method).
      Context = Struct.new(:resource, :rendering, :serializer, keyword_init: true)

      def initialize(mapping, root, dirs, terms:, policies:)
        @mapping = mapping
        @root = root
        @index = SourceIndex.new(root, dirs)
        @translator = MethodTranslator.new(@index, terms)
        @user = mapping.principal_source.is_a?(Symbol) ? mapping.principal_source.to_s : "user"
        @conditions = Conditions.new(mapping, @index, @translator, terms: terms, policies: policies)
        @shown = {}
        @grape = GrapeEntity.new
        @active_model = ActiveModel.new
        @serializers = nil
      end

      # Every entity and serializer class, by name.
      def serializers
        @serializers ||= @index.scopes.keys.sort.select do |name|
          @index.scopes.fetch(name).module != true && dialect(name)
        end
      end

      # :grape or :active_model; nil for any other class.
      def dialect(name)
        return :grape if @index.inherits?(name, GRAPE)

        @index.inherits?(name, AMS) ? :active_model : nil
      end

      # The fields a serializer shows as written, ancestors first.
      def shown(name)
        @shown[name] ||= begin
          reader = dialect(name) == :grape ? @grape : @active_model
          found = {}
          @index.ancestors(name).reverse.each { |ancestor| reader.apply(found, @index.scopes.fetch(ancestor)) }
          found.values
        end
      end

      # The serializer a rendering names, resolved to an indexed entity or
      # serializer; nil when it cannot be told.
      def resolve(rendering, resource = nil)
        written = rendering.serializer
        return written && serializer_named(written, rendering.namespace) unless rendering.default

        model = resource || rendering.model
        name = model && "#{model}Serializer"
        name && serializers.include?(name) ? name : nil
      end

      # The resource a serializer's records are: the mapping's `serializer`
      # declaration, else its name without `Serializer` or `Entity` with
      # leading namespaces dropped until a mapped resource matches
      # (REST::Admin::AccountSerializer is Account,
      # API::Entities::Ci::PipelineSchedule is Ci::PipelineSchedule), else
      # its nearest app ancestor's.
      def resource_of(name)
        classes = [name] + @index.ancestors(name).reject { |each| each == name || @index.scopes.fetch(each).module }
        classes.each do |each|
          found = @mapping.serializers[each]&.resource || named_resource(each)
          return found if found
        end
        nil
      end

      # The fields `name` shows in one rendering of records of `resource`,
      # each with its condition read for that rendering's options; with no
      # rendering (`hallmark extract`), options are left as written.
      def fields(name, resource, rendering = nil)
        shown(name).map do |each|
          condition = each.conditions.reduce(Guard.new(:none)) do |all, item|
            Guard.conjoin(all, condition_guard(item, resource, rendering, serializer: name))
          end
          Field.new(serializer: each.serializer, name: each.name, key: each.key, condition: condition,
                    location: each.location, resource: nested_resource(each))
        end
      end

      # One condition as written, read on a record of `resource` for a
      # rendering's options (left as written with no rendering).
      def condition_guard(condition, resource, rendering = nil, serializer: condition.owner)
        @conditions.guard(condition, Context.new(resource: resource, rendering: rendering, serializer: serializer))
      end

      # A Grape branch's condition (a ternary `with:`, an `if` around a
      # `present`), read on a record of `resource`.
      def branch_guard(branch, resource)
        guard = @translator.expression(branch.node, branch.definition, branch.klass, resource,
                                       locals: branch.locals, aliases: { "current_user" => @user }, file: branch.file)
        branch.negated ? Guard.negate(guard) : guard
      end

      # Jbuilder views under the root: counted, not read.
      def jbuilder_views = Dir.glob(File.join(@root, JBUILDER)).size

      # Names a node gives (`expose :a, "b"`, `attributes :a`): Symbols
      # and Strings, from a list given as one Array too.
      def self.names(call)
        args = call.arguments&.arguments || []
        first = args.first
        args = first.elements if first.is_a?(Prism::ArrayNode)
        args.filter_map { |arg| literal_name(arg) }
      end

      def self.literal_name(node)
        node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode) ? node.unescaped : nil
      end

      # A call's keyword arguments by name, as written.
      def self.keywords(call)
        hash = (call.arguments&.arguments || []).find { |arg| arg.is_a?(Prism::KeywordHashNode) }
        pairs(hash)
      end

      def self.pairs(hash)
        return {} unless hash.is_a?(Prism::KeywordHashNode) || hash.is_a?(Prism::HashNode)

        hash.elements.grep(Prism::AssocNode).each_with_object({}) do |pair, found|
          name = literal_name(pair.key)
          found[name] = pair.value if name
        end
      end

      # A constant as written ("::API::Entities::UserBasic"), or a
      # String's contents; nil for anything else.
      def self.constant_text(node)
        case node
        when Prism::ConstantReadNode, Prism::ConstantPathNode then node.slice
        when Prism::StringNode then "::#{node.unescaped.delete_prefix("::")}"
        end
      end

      # A lambda or proc's parameters and body: `->(a, b) { }`, `lambda {
      # |a| }`, `proc { }`, `Proc.new { }`; nil for anything else.
      def self.lambda_parts(node)
        case node
        when Prism::LambdaNode then [parameter_names(node.parameters), node.body]
        when Prism::CallNode
          block = node.block
          return nil unless block.is_a?(Prism::BlockNode) && %i[lambda proc new].include?(node.name)

          [parameter_names(block.parameters), block.body]
        end
      end

      def self.parameter_names(node)
        list = node.is_a?(Prism::BlockParametersNode) ? node.parameters : nil
        (list&.requireds || []).map { |param| param.is_a?(Prism::RequiredParameterNode) ? param.name.to_s : "" }
      end

      def self.join(prefix, name) = prefix ? "#{prefix}.#{name}" : name

      def self.statements(node)
        case node
        when Prism::StatementsNode then node.body
        when nil then []
        else [node]
        end
      end

      private

      def serializer_named(written, namespace)
        found = @index.resolve_constant(written, namespace)
        found && dialect(found) ? found : nil
      end

      def named_resource(name)
        parts = name.split("::")
        last = parts.pop.to_s.sub(/(?:Serializer|Entity)\z/, "")
        return nil if last.empty?

        parts << last
        candidates = Array.new(parts.size) { |drop| parts.drop(drop).join("::") }
        candidates.find { |candidate| @mapping.resources.key?(candidate) }
      end

      # A mapped resource the field's association shows, by the serializer
      # it names, else (naming none) by the association's name, singular
      # and camelized; nil for an unmapped one, which is a field.
      def nested_resource(shown)
        return nil unless shown.association

        written = shown.nested
        if written
          found = serializer_named(written, shown.namespace)
          return found ? resource_of(found) : named_resource(written.delete_prefix("::"))
        end
        name = Naming.class_name(singular(shown.name).split("_").map(&:capitalize).join)
        @mapping.resources.key?(name) ? name : nil
      end

      def singular(name)
        return "#{name.delete_suffix("ies")}y" if name.end_with?("ies")

        name.end_with?("ses") ? name.delete_suffix("es") : name.delete_suffix("s")
      end
    end
  end
end

require_relative "serializers/grape_entity"
require_relative "serializers/active_model"
require_relative "serializers/conditions"
