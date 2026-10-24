# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # What clears the revocation lint's caches (role_reads.rb): callbacks on
    # the membership, principal and tenant classes.
    class RoleReads
      # Model callbacks that run when a membership, user or tenant changes.
      CALLBACKS = %i[after_commit after_create_commit after_update_commit after_destroy_commit after_save_commit
                     after_save after_create after_update after_destroy before_destroy after_touch].freeze
      # Declarations taking `after_add:` and `after_remove:` callbacks
      # (Rolify's `rolify` among them).
      HOOKED = %i[has_many has_and_belongs_to_many rolify].freeze
      CLEARS = %i[delete delete_multi delete_matched write].freeze
      RESETS = %i[clear delete delete_if reject! remove_instance_variable].freeze

      # What a callback reaches that clears a cache: a key deleted or
      # rewritten (`kind` :key), a `delete_matched` glob or regexp (:glob,
      # :regexp), or a class-level memo reset (:reset, `text` the variable),
      # in `owner`'s code, through `via` (the callback), at `location`.
      Deletion = Struct.new(:kind, :text, :owner, :via, :location, keyword_init: true) do
        def to_s = "by #{via} (#{location})"
      end

      private

      # Decides each cache: accepted by `cache_ok`, cleared by a callback
      # or a touch, or an R1 lint.
      def judge
        classes = clearing_classes
        deletions = classes.flat_map { |klass| callbacks_of(klass) }.uniq
        @caches.each do |cache|
          cache.searched = classes
          cache.cleared = clearing(cache, deletions) if cache.clearable?
          next unless (reason = @mapping.caches_ok[cache.holder])

          cache.accepted = reason
          @accepted << Accepted.new(holder: cache.holder, location: cache.location, reason: reason)
        end
      end

      # The membership, principal and tenant classes, as the index holds them.
      def clearing_classes
        names = [@mapping.tenancy&.membership, principal, tenant_class].compact.uniq
        names.select { |name| index_for(name) }
      end

      # What one class's callbacks (its own and its ancestors') reach.
      def callbacks_of(klass)
        index = index_for(klass)
        return [] unless index

        index.calls(klass).flat_map do |call|
          if CALLBACKS.include?(call.name)
            callback_deletions(klass, call)
          elsif HOOKED.include?(call.name)
            hooks = Caches.options(call.arguments).values_at("after_add", "after_remove").compact
            hooks.flat_map { |hook| symbols(hook) }.uniq.flat_map do |name|
              clear_walk(klass, name, "#{call.owner} #{call.name} #{name}", 0, Set.new)
            end
          else
            []
          end
        end
      end

      def callback_deletions(klass, call)
        via = "#{call.owner} #{call.name}"
        block = call.node.block
        found = call.arguments.flat_map { |arg| symbols(arg) }.flat_map do |name|
          clear_walk(klass, name, "#{via} :#{name}", 0, Set.new)
        end
        return found unless block.is_a?(Prism::BlockNode)

        frame = Frame.new(klass: klass, singleton: false, env: {}, file: call.file, path: [], depth: 0,
                          start: Start.new(label: via, walked: []))
        found + deletions_in(block.body, frame, via, Set.new)
      end

      def symbols(node)
        case node
        when Prism::SymbolNode then [node.unescaped]
        when Prism::ArrayNode then node.elements.grep(Prism::SymbolNode).map(&:unescaped)
        else []
        end
      end

      # The deletions a method reaches, at most DEPTH calls deep.
      def clear_walk(klass, name, via, depth, seen)
        method = find_method(klass, name)
        return [] if method.nil? || depth > DEPTH || !seen.add?([method.owner, method.name])

        frame = Frame.new(klass: klass, singleton: method.name.start_with?("self."), env: {}, file: method.file,
                          path: [], depth: depth, start: Start.new(label: via, walked: []))
        deletions_in(method.node.body, frame, via, seen)
      end

      def deletions_in(node, frame, via, seen)
        return [] unless node

        locals = locals_of(node, frame)
        found = []
        each_node(node) do |child|
          found.concat(deletion(child, frame, via, locals))
          found.concat(followed(child, frame, via, seen)) if child.is_a?(Prism::CallNode)
        end
        found
      end

      # Calls the clearing search follows, as the walk does, without
      # listing what it cannot follow.
      def followed(call, frame, via, seen)
        @quiet = true
        target = callee(call, frame)
        target ? clear_walk(target[0], target[1], via, frame.depth + 1, seen) : []
      ensure
        @quiet = false
      end

      def deletion(node, frame, via, locals)
        location = "#{frame.file}:#{node.location.start_line}"
        case node
        when Prism::CallNode then call_deletions(node, frame, via, locals, location)
        when Prism::InstanceVariableWriteNode, Prism::ClassVariableWriteNode
          reset_of(node.name.to_s, node.value, frame, via, location)
        else []
        end
      end

      def call_deletions(call, frame, via, locals, location)
        return cache_deletions(call, frame, via, locals) if rails_cache?(call.receiver, frame, locals)
        return [] unless RESETS.include?(call.name)

        variable = reset_target(call)
        variable ? [Deletion.new(kind: :reset, text: variable, owner: frame.klass, via: via, location: location)] : []
      end

      def cache_deletions(call, frame, via, locals)
        location = "#{frame.file}:#{call.location.start_line}"
        first = call.arguments&.arguments&.first
        return [matched(first, frame, locals, via, location)].compact if call.name == :delete_matched

        deleted_keys(call, first).filter_map { |node| key_of(node, frame, locals) }.map do |text|
          Deletion.new(kind: :key, text: text, owner: frame.klass, via: via, location: location)
        end
      end

      # The key nodes a deletion names: `delete_multi`'s list, the key of a
      # `delete` or `write`, or of a `fetch(..., force: true)`.
      def deleted_keys(call, first)
        case call.name
        when :delete_multi then first.is_a?(Prism::ArrayNode) ? first.elements : [first]
        when *CLEARS then [first]
        when :fetch then Caches.options(call.arguments&.arguments || [])["force"].is_a?(Prism::TrueNode) ? [first] : []
        else []
        end
      end

      # `delete_matched` by a glob (a string key template) or a regexp.
      def matched(node, frame, locals, via, location)
        if node.is_a?(Prism::RegularExpressionNode)
          return Deletion.new(kind: :regexp, text: node.unescaped, owner: frame.klass, via: via, location: location)
        end

        text = key_of(node, frame, locals)
        text && Deletion.new(kind: :glob, text: text, owner: frame.klass, via: via, location: location)
      end

      # `@x.clear`, `@@x.delete(...)`, `CONST.clear` and
      # `remove_instance_variable(:@x)`.
      def reset_target(call)
        receiver = call.receiver
        if call.name == :remove_instance_variable
          arg = call.arguments&.arguments&.first
          return arg.is_a?(Prism::SymbolNode) ? arg.unescaped : nil
        end
        case receiver
        when Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode, Prism::ConstantReadNode
          receiver.name.to_s
        end
      end

      # `@x = nil`, `@x = {}` or `@x = []`; an instance variable only in a
      # class method, where it is the class's own.
      def reset_of(name, value, frame, via, location)
        return [] unless Caches.empty_value?(value)
        return [] if name.start_with?("@") && !name.start_with?("@@") && !frame.singleton

        [Deletion.new(kind: :reset, text: name, owner: frame.klass, via: via, location: location)]
      end

      # What clears a cache, as a phrase; nil when nothing does.
      def clearing(cache, deletions)
        return deletions.find { |item| matches?(item, cache.key) }&.to_s || touched_by(cache) unless memo?(cache)

        deletions.find { |item| reset?(item, cache) }&.to_s
      end

      # A reset of the memo's variable in its own class's code.
      def reset?(deletion, cache)
        deletion.kind == :reset && deletion.text == cache.key && deletion.owner == cache.owner
      end

      def memo?(cache) = cache.shape.start_with?("class-level memo")

      def matches?(deletion, key)
        return false unless key

        case deletion.kind
        when :key then deletion.text == key
        when :glob then File.fnmatch(deletion.text, key)
        when :regexp then Regexp.new(deletion.text).match?(key.gsub("{}", "0"))
        else false
        end
      rescue RegexpError
        false
      end

      # A key that interpolates `updated_at` (or a cache key or version) of
      # an object the membership `touch:`es is fresh after each change.
      def touched_by(cache)
        membership = @mapping.tenancy&.membership
        index = cache.versions.any? ? index_for(membership) : nil
        return nil unless index

        touch = index.calls(membership.to_s).find { |call| touching?(membership.to_s, call, cache.versions) }
        touch && "by touch: #{touch.owner} belongs_to :#{touch.arguments.first&.slice&.delete_prefix(":")}, " \
                 "touch: true (#{touch.location})"
      end

      # `belongs_to :user, touch: true` toward one of `versions`.
      def touching?(membership, call, versions)
        name = call.arguments.first
        return false unless call.name == :belongs_to && name.is_a?(Prism::SymbolNode)

        Caches.options(call.arguments)["touch"].is_a?(Prism::TrueNode) &&
          versions.include?(association(membership, name.unescaped).to_s)
      end
    end
  end
end
