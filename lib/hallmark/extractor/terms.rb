# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # What Ruby expressions in policy code mean in catalog terms, keyed by
    # their normalized source (`Terms.normalize`). Seeded from the mapping,
    # then extended by its `term` declarations, which win:
    #
    #   principal ..., from: :user   user, user.present? (logged_in); user.nil?, user.blank?
    #   resource ..., owner: :author record.author == user, record.author_id == user.id (owner)
    #   resource ..., public_if: :published?   record.published? (public_record)
    #   resource ..., tenant: :user, with current_tenant :seller
    #                                record.user == seller, record.user_id == seller.id (in_current_tenant)
    #   platform_role :staff         user.staff, user.staff? (role(:staff))
    #   resource ..., permits: :collaborator_for?   user.collaborator_for?(record) (permitted)
    #   resource ..., kind: :profile record == user (owner: the user it describes)
    #
    # A record is never a class in a record-level check, so
    # `record.is_a?(Class)` is false, and it exists, so `record.present?` is
    # true and `record.nil?` and `record.blank?` are false.
    class Terms
      include Guard::DSL

      RECORD = "record"

      def initialize(mapping)
        @mapping = mapping
        @global = {}
        @by_resource = {}
        seed
        mapping.terms.each { |source, guard| @global[Terms.normalize(source)] = guard }
      end

      # The guard a normalized expression stands for when checking a record
      # of `resource`, or nil.
      def lookup(source, resource)
        @global[source] || ((table = resource && @by_resource[resource]) && table[source])
      end

      # A comparison, in either order. `==` and `eql?` both read as "==".
      def compare(left, right, resource)
        lookup("#{left} == #{right}", resource) || lookup("#{right} == #{left}", resource)
      end

      # What it means for a record of `resource` to be held by `source`
      # through an association (`user.links`): its owner or its tenant is
      # that object. Nil when neither reader compares to it.
      def holder(source, resource)
        readers = (mapped = @mapping.resources[resource]) ? [mapped.owner, mapped.tenant].grep(Symbol) : []
        readers.lazy.filter_map { |reader| compare("#{RECORD}.#{reader}", source, resource) }.first
      end

      # A list filtered on the record's tenant being one of the user's
      # (`where(organization: user.organizations)`, `organization_id:
      # user.organization_ids`): membership of the record's tenant, by the
      # tenant class's name. Nil for any other pair.
      def membership(key, source, resource)
        tenancy = @mapping.tenancy
        reader = resource && @mapping.resources[resource]&.tenant
        return nil unless tenancy && reader.is_a?(Symbol) && [reader.to_s, "#{reader}_id"].include?(key)

        user = @mapping.principal_source.is_a?(Symbol) ? @mapping.principal_source.to_s : "user"
        lists = ["#{user}.#{Naming.plural(tenancy.name)}", "#{user}.#{Naming.underscore(tenancy.name)}_ids"]
        lists.include?(source) ? member : nil
      end

      # Normalized Ruby source: Prism's own reading of it, with spacing,
      # parentheses around a lone expression, `self.` and the `@` of
      # instance variables dropped, so `@record.user != seller` and
      # `record.user != self.seller` both normalize the same way.
      def self.normalize(source)
        node = Prism.parse(source.to_s).value.statements.body.first
        node ? Canonical.new({}).render(node) : source.to_s
      end

      private

      def seed
        user = @mapping.principal_source.is_a?(Symbol) ? @mapping.principal_source.to_s : "user"
        [user, "#{user}.present?"].each { |source| @global[source] = logged_in }
        ["#{user}.nil?", "#{user}.blank?"].each { |source| @global[source] = ~logged_in }
        @mapping.platform_roles.each do |name|
          ["#{user}.#{name}", "#{user}.#{name.delete_suffix("?")}?"].each { |source| @global[source] = role(name) }
        end
        @global["#{RECORD}.is_a?(Class)"] = Guard.new(:never)
        @global["#{RECORD}.present?"] = Guard.new(:none)
        ["#{RECORD}.nil?", "#{RECORD}.blank?"].each { |source| @global[source] = Guard.new(:never) }
        @mapping.resources.each_value { |resource| seed_resource(resource, user) }
      end

      def seed_resource(resource, user)
        terms = @by_resource[resource.name] = {}
        if (reader = resource.owner).is_a?(Symbol)
          terms["#{RECORD}.#{reader} == #{user}"] = owner
          terms["#{RECORD}.#{reader}_id == #{user}.id"] = owner
        end
        terms["#{RECORD}.#{resource.public_if}"] = public_record if resource.public_if.is_a?(Symbol)
        terms["#{user}.#{resource.permits}(#{RECORD})"] = permitted if resource.permits.is_a?(Symbol)
        terms["#{RECORD} == #{user}"] = owner if resource.kind == :profile
        seed_tenant(terms, resource)
      end

      def seed_tenant(terms, resource)
        current = @mapping.current_tenant_source
        reader = resource.tenant
        return unless current.is_a?(Symbol) && reader.is_a?(Symbol)

        terms["#{RECORD}.#{reader} == #{current}"] = in_current_tenant
        terms["#{RECORD}.#{reader}_id == #{current}.id"] = in_current_tenant
      end
    end

    # Renders a Prism node as normalized source. `locals` maps a local
    # variable's name to the node it was assigned and the locals in force
    # there, so `seller = record.user; seller == user` reads as
    # `record.user == user`. `aliases` renames what controller code calls
    # the policy's names: an instance variable (`"@product" => "record"`), a
    # local no assignment explains, a receiverless reader with no arguments
    # (`"current_seller" => "seller"`), or a whole call as rendered
    # (`"context[:current_user]" => "user"`, for graphql-ruby's checks), or
    # a constant (`"Link" => "scope"`, for list scopes).
    # `x[:key]` renders as written.
    class Canonical
      OPERATORS = %i[== != eql? equal? < > <= >= === =~].freeze

      def initialize(locals, aliases = {})
        @locals = locals
        @aliases = aliases
      end

      def render(node)
        case node
        when Prism::CallNode then reader(node) || renamed(call(node))
        when Prism::LocalVariableReadNode then local(node)
        when Prism::InstanceVariableReadNode then @aliases.fetch(node.name.to_s) { node.name.to_s.delete_prefix("@") }
        when Prism::ParenthesesNode then parentheses(node)
        when Prism::SymbolNode then ":#{node.unescaped}"
        when Prism::SelfNode then "self"
        when Prism::ConstantReadNode, Prism::ConstantPathNode then @aliases.fetch(node.slice.delete_prefix("::"),
                                                                                  node.slice)
        else node.slice.gsub(/\s+/, " ")
        end
      end

      private

      def call(node)
        receiver = node.receiver
        operated = receiver && operator(node, receiver)
        return operated if operated

        prefix = receiver && !receiver.is_a?(Prism::SelfNode) ? "#{render(receiver)}." : ""
        args = arguments(node)

        "#{prefix}#{node.name}#{"(#{args.join(", ")})" if args.any?}"
      end

      # `!x`, comparisons and `x[:key]`; nil for any other call.
      def operator(node, receiver)
        name = node.name
        return "!#{render(receiver)}" if name == :!
        return "#{render(receiver)} #{name} #{arguments(node).first}" if OPERATORS.include?(name)

        "#{render(receiver)}[#{arguments(node).join(", ")}]" if name == :[]
      end

      # A receiverless reader with no arguments that `aliases` renames.
      def reader(node)
        return nil unless node.receiver.nil? && node.arguments.nil? && node.block.nil?

        @aliases[node.name.to_s]
      end

      # A whole call `aliases` renames (`context[:current_user]`).
      def renamed(text) = @aliases.fetch(text, text)

      def arguments(node) = (node.arguments&.arguments || []).map { |arg| render(arg) }

      def local(node)
        assigned = @locals[node.name.to_s]
        return Canonical.new(assigned[1], @aliases).render(assigned[0]) if assigned

        @aliases.fetch(node.name.to_s, node.name.to_s)
      end

      def parentheses(node)
        body = node.body
        inner = body.is_a?(Prism::StatementsNode) && body.body.size == 1 ? body.body.first : nil
        inner ? render(inner) : node.slice
      end
    end
  end
end
