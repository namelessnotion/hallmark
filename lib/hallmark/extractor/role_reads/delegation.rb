# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # How the revocation lint follows `delegate` (role_reads.rb): Forem's
    # User sends its role questions to an authorizer, and policies
    # delegate prefixed readers to the user.
    class RoleReads
      private

      # Where `delegate :name, to: :target` (with `prefix:`) sends a method
      # the class does not define: the target's class and the method's
      # name there; nil when no delegation names it or its target cannot be
      # typed.
      def delegated(klass, name)
        index = klass && index_for(klass)
        return nil unless klass && index

        index.calls(klass).each do |call|
          method, target = delegation(call, name)
          owner = target && delegate_target(klass, target)
          return [owner, method.to_s] if owner
        end
        nil
      end

      # The method and target a `delegate` call names for `name`, or nil.
      def delegation(call, name)
        options = Caches.options(call.arguments)
        target = options["to"]
        return nil unless call.name == :delegate && target.is_a?(Prism::SymbolNode)

        prefix = delegate_prefix(options["prefix"], target.unescaped)
        method = call.arguments.grep(Prism::SymbolNode).map(&:unescaped).find { |each| "#{prefix}#{each}" == name }
        method ? [method, target.unescaped] : nil
      end

      def delegate_prefix(option, target)
        case option
        when Prism::TrueNode then "#{target}_"
        when Prism::SymbolNode then "#{option.unescaped}_"
        else ""
        end
      end

      # A delegation's target: an association, the user or tenant a policy
      # reads, or what a reader of the class returns.
      def delegate_target(klass, target)
        association(klass, target) || (@policies.scopes.key?(klass) ? user_env[target] : nil) ||
          returned_class(klass, target, 0)
      end

      # The class a method returns, when its last expression builds one:
      # `Const.new(...)`, or a class method that does (`@x ||=` unwrapped).
      def returned_class(klass, name, depth)
        method = depth <= 2 ? find_method(klass, name) : nil
        last = method && last_expression(method)
        method && last.is_a?(Prism::CallNode) ? built_class(last, method.owner, depth) : nil
      end

      # What a call builds: `new(...)` in a class method its own class,
      # `Const.new` the constant, `Const.for(...)` what that method returns.
      def built_class(call, owner, depth)
        receiver = call.receiver
        return owner if call.name == :new && (receiver.nil? || receiver.is_a?(Prism::SelfNode))
        return nil unless receiver.is_a?(Prism::ConstantReadNode)

        constant = resolve_in(receiver.name.to_s, owner)
        return constant if constant.nil? || call.name == :new

        returned_class(constant, "self.#{call.name}", depth + 1)
      end

      # A method's last expression, a memo (`@x ||= value`) read as its value.
      def last_expression(method)
        body = method.node.body
        last = body.is_a?(Prism::StatementsNode) ? body.body.last : body
        last.is_a?(Prism::InstanceVariableOrWriteNode) ? last.value : last
      end
    end
  end
end
