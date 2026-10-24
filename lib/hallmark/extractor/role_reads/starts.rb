# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # The revocation lint's start points (role_reads.rb): the mapping's role
    # readers, its terms, and the rules and conditions the extractor read.
    class RoleReads
      private

      # Start points, in the order the lint lists them.
      def read_starts(rules)
        reader_start("principal roles", @mapping.principal_roles, [principal])
        if (tenancy = @mapping.tenancy)
          reader_start("tenant roles_in", tenancy.roles_in, [principal, tenancy.name])
        end
        @mapping.terms.each_key { |source| term_start(source) }
        rules.each { |rule| rule_start(rule) }
      end

      # A reader option: a Symbol is a method on the principal, whose first
      # parameter is the tenant for `roles_in:`; a lambda is read from where
      # it is written, its parameters bound to `classes` in order.
      def reader_start(label, source, classes)
        case source
        when Symbol
          start = add_start("#{label} (:#{source})")
          visit(principal, source.to_s, frame(principal, {}, start, ""), site: start.label, bind: classes.drop(1))
        when Proc then lambda_start(label, source, classes)
        end
      end

      def lambda_start(label, source, classes)
        start = add_start("#{label} (a lambda)")
        file, line = source.source_location
        node = File.file?(file.to_s) ? lambda_at(file.to_s, line) : nil
        unless node
          @unread << Unread.new(call: "#{label}: a lambda Hallmark could not read",
                                location: "#{relative(file.to_s)}:#{line}", start: start.label)
          return
        end

        env = parameter_names(node).zip(classes).to_h.compact
        scan(node.body, frame(nil, env, start, relative(file.to_s)))
      end

      # The one lambda (`->`, `lambda`, `proc`) that starts on `line`,
      # wherever it is in the file (a method's body included).
      def lambda_at(file, line)
        found = all_nodes(Prism.parse_file(file).value).select do |node|
          lambda_node?(node) && node.location.start_line == line
        end
        found.size == 1 ? lambda_body(found.fetch(0)) : nil
      end

      def all_nodes(root)
        out = []
        stack = [root]
        while (node = stack.pop)
          out << node
          stack.concat(node.compact_child_nodes)
        end
        out
      end

      def lambda_node?(node)
        return true if node.is_a?(Prism::LambdaNode)

        node.is_a?(Prism::CallNode) && %i[lambda proc].include?(node.name) && node.receiver.nil? && !node.block.nil?
      end

      def lambda_body(node) = node.is_a?(Prism::CallNode) ? node.block : node

      def parameter_names(node)
        params = node.parameters
        params = params.parameters if params.is_a?(Prism::BlockParametersNode)
        return [] unless params.is_a?(Prism::ParametersNode)

        params.requireds.grep(Prism::RequiredParameterNode).map { |param| param.name.to_s }
      end

      # A `term` source, parsed as an expression: `user` is the principal and
      # the current tenant's reader is the tenant.
      def term_start(source)
        node = Prism.parse(source.to_s).value.statements.body.first
        return unless node

        start = add_start("term #{source.inspect}")
        scan(node, frame(nil, user_env, start, ""))
      end

      # A rule the extractor read: a Pundit or Action Policy method, or a
      # DeclarativePolicy policy's conditions.
      def rule_start(rule)
        policy = rule.policy
        env = user_env.merge(record_env(rule.resource))
        if @policies.declarative?(policy)
          @policies.ancestors(policy).each do |name|
            @policies.scopes.fetch(name).conditions.each_value { |condition| condition_start(policy, condition, env) }
          end
          return
        end
        return unless (method = @policies.find_method(policy, rule.rule))

        start = add_start(rule.key)
        visit(policy, rule.rule, frame(policy, env, start, method.file), site: method.location, method: method)
      end

      def condition_start(policy, condition, env)
        key = "#{condition.owner}.condition(:#{condition.name})"
        return if @visited.key?(key)

        @visited[key] = 0
        start = add_start("#{policy} condition(:#{condition.name})")
        start.walked << key
        scan(condition.body, frame(policy, env, start, condition.file).tap { |each| each.path = [key] })
      end

      # The names a policy or term calls the user and the current tenant.
      def user_env
        env = %w[user @user current_user].to_h { |name| [name, principal] }
        source = @mapping.principal_source
        env[source.to_s] = env["@#{source}"] = principal if source.is_a?(Symbol)
        current = @mapping.current_tenant_source
        if current.is_a?(Symbol) && (tenant = tenant_class)
          env[current.to_s] = env["@#{current}"] = tenant
        end
        env
      end

      def record_env(resource)
        return {} unless resource

        %w[record @record subject @subject].to_h { |name| [name, resource] }
      end

      def add_start(label)
        start = Start.new(label: label, walked: [])
        @starts << start
        start
      end
    end
  end
end
