# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # Reads Rails controllers under `app/controllers` (phase 2 step 3), for
    # what an entry point's stamps cannot say:
    #
    # - how the record it authorizes was loaded: through the current tenant
    #   (`current_seller.products.find(...)`, scoped), from a model class
    #   (`Link.find(...)`, unscoped), or some other way (unknown). The
    #   controller's current tenant reader comes from the mapping
    #   (`current_tenant :seller, controller: :current_seller`).
    # - whether the app exempts the action from `verify_authorized`
    #   (`after_action :verify_authorized, except: PUBLIC_ACTIONS`, or
    #   `skip_after_action :verify_authorized`), so an unchecked request
    #   there is intended.
    # - which rules it authorizes, for routes no test reached: the policy
    #   from `policy_class:`/`with:` or the record's model class (`Link.find`
    #   is a Link; `current_seller.links.find` is a Link when Link is mapped),
    #   and the rule from the call or the action's name (`update?`).
    # - the checks it makes in its own code, outside any policy: a way out
    #   guarded by a condition (`e404 unless product.user == current_seller`,
    #   `head :forbidden unless ...`, `redirect_to ... and return if ...`),
    #   read as a guard by the policies' `MethodTranslator` (`#checks`).
    #
    # The action body and the `before_action` callbacks that run for it are
    # read, with the controller's own argument-less helpers a few levels
    # down. Nothing is loaded.
    class Controllers
      DIRS = %w[app/controllers].freeze
      AUTHORIZE = %i[authorize authorize!].freeze
      # Calls that leave the request anywhere, and calls that end it from a
      # `before_action` (Rails halts the chain once a callback renders).
      RAISES = %i[raise fail].freeze
      HALTS = %i[head render redirect_to redirect_back redirect_back_or_to].freeze
      # Guard leaves that read the record.
      ON_RECORD = %i[owner public in_current_tenant outside_tenants permitted].freeze
      # Calls that count as an authorization check at run time.
      CHECKS = %i[authorize authorize! policy_scope authorized_scope skip_authorization skip_policy_scope
                  skip_verify_authorized!].freeze
      VERIFY = "verify_authorized"
      # How far helpers that load a record are followed.
      DEPTH = 4
      LOCAL_WRITES = [Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode].freeze
      IVAR_WRITES = [Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode].freeze

      # `loading` is :scoped, :unscoped or :unknown (nil when the entry point
      # authorizes no record), `location` the first authorize call's
      # file:line, `verify` :required, :skipped or nil (the app declares no
      # `verify_authorized`), `authorizations` each record-level authorize
      # call, `checked` whether any check call (`CHECKS`) runs, `records`
      # the variables holding the records it authorizes (`@product`,
      # `link`), and `exits` the guarded ways out of the request.
      EntryPoint = Struct.new(:name, :loading, :location, :verify, :authorizations, :checked, :records, :exits,
                              keyword_init: true) do
        def scoped? = loading == :scoped
      end

      # A way out of the request: it goes on only where `condition` holds,
      # or fails to when `negated` (`e404 if ...`). `locals` are the locals
      # assigned before it in `definition`, the method it is in.
      Exit = Struct.new(:condition, :negated, :definition, :locals, :location, keyword_init: true)

      # A condition on the request read from the controller, as a guard that
      # may hold opaque leaves, and where it is.
      Check = Struct.new(:guard, :location, keyword_init: true)

      # One authorize call: the policy (nil when the record's class is not
      # known) and the rule it checks. When the class is not known,
      # `named_policy` is the policy the record's variable names by Pundit's
      # convention (`authorize @event` names EventPolicy), a guess only
      # `Ops` reads.
      Authorization = Struct.new(:policy, :rule, :location, :named_policy, keyword_init: true)

      # How a value was loaded, and its model class when known.
      Load = Struct.new(:kind, :model, keyword_init: true)

      def initialize(mapping, root)
        @index = SourceIndex.new(File.expand_path(root), DIRS)
        reader = mapping.current_tenant_controller
        @tenant_reader = reader&.to_s
        @resources = mapping.resources.keys
        @tenant_keys = mapping.resources.values.select { |resource| resource.tenant.is_a?(Symbol) }
                              .to_h { |resource| [resource.name, resource.tenant.to_s] }
        @translator = MethodTranslator.new(@index, Terms.new(mapping))
        @aliases = aliases(mapping)
        @cache = {}
        @checks = {}
        @authorizes = {}
      end

      # Where the action is defined ("app/controllers/links_controller.rb:12"),
      # or nil when it is not in an indexed controller.
      def action_location(entry_point)
        controller, action = entry_point.split("#", 2)
        return nil unless controller && action && @index.scopes.key?(controller)

        @index.find_method(controller, action)&.location
      end

      # The entry point "Controller#action", or nil when no indexed
      # controller has that name.
      def fetch(entry_point)
        return @cache[entry_point] if @cache.key?(entry_point)

        @cache[entry_point] = read(entry_point)
      end

      # What the entry point's own code requires of a record of `resource`
      # before its authorize call: each guarded way out whose condition reads the
      # record it authorizes, or reads exactly (no opaque leaf). The
      # controller's names become the policy's: the record variables
      # `record`, the current tenant reader the mapping's current tenant,
      # and the signed-in user reader (`principal ..., controller:`) the
      # policy's user. Empty when the controller is not read.
      def checks(entry_point, resource)
        key = [entry_point, resource]
        return @checks.fetch(key) if @checks.key?(key)

        @checks[key] = read_checks(entry_point, resource)
      end

      private

      # Controller names => the policy's: the current tenant and user readers.
      def aliases(mapping)
        found = {}
        current = mapping.current_tenant_source
        found[@tenant_reader.to_s] = current.to_s if @tenant_reader && current.is_a?(Symbol)
        source = mapping.principal_source
        user = mapping.principal_controller
        found[user] = source.is_a?(Symbol) ? source.to_s : "user" if user
        found
      end

      def read_checks(entry_point, resource)
        read = fetch(entry_point)
        return [] unless read

        controller = entry_point.split("#", 2).fetch(0)
        aliases = @aliases.merge(read.records.to_h { |name| [name, Terms::RECORD] })
        read.exits.filter_map { |exit| check_for(exit, controller, resource, aliases) }
      end

      # The check a way out makes, when its condition reads the record or
      # reads exactly.
      def check_for(exit, controller, resource, aliases)
        locals = exit.locals.reject { |name, _| aliases.key?(name) }
        guard = @translator.expression(exit.condition, exit.definition, controller, resource, locals: locals,
                                                                                              aliases: aliases)
        guard = Guard.negate(guard) if exit.negated
        return nil unless on_record?(guard) || (!guard.opaque? && guard.kind != :none)

        Check.new(guard: guard, location: exit.location)
      end

      def on_record?(guard)
        guard.leaves.any? do |leaf|
          case leaf.kind
          when :role then leaf.operands[1] == :record
          when :opaque then leaf.operands[0].to_s.match?(/\b#{Terms::RECORD}\b/o)
          else ON_RECORD.include?(leaf.kind)
          end
        end
      end

      def read(entry_point)
        controller, action = entry_point.split("#", 2)
        return nil unless controller && action && @index.scopes.key?(controller)

        methods = run_methods(controller, action)
        reach = reachable(controller, methods)
        records = records_in(reach)
        loads = records.map { |record, method, _| classify(controller, record, method, reach, 0) }
        EntryPoint.new(name: entry_point, loading: loads.empty? ? nil : combine(loads).kind,
                       location: first_location(records), verify: verify(controller, action),
                       authorizations: authorizations(action, records, loads), checked: checked?(reach),
                       records: record_names(records), exits: exits(controller, methods, action))
      end

      # The variables an entry point's authorize calls pass: "@product" or a
      # local's name.
      def record_names(records)
        records.filter_map do |record, _, _|
          if record.is_a?(Prism::InstanceVariableReadNode) || record.is_a?(Prism::LocalVariableReadNode)
            record.name.to_s
          end
        end.uniq
      end

      # The guarded ways out that run for `action` before its first
      # authorize call: in the `before_action` callbacks, then the action,
      # and in the controller's argument-less helpers they call as
      # statements, DEPTH levels down. A way out after the authorize call is
      # the action's own logic (a validation error, a redirect elsewhere),
      # and one inside a branch or a block may not run, so neither is read.
      # The context says what ends the request: in a callback, a render or
      # redirect (Rails halts the chain); in the action, a `return`; in a
      # helper the action calls, only a raise.
      def exits(controller, methods, action)
        found = []
        methods.each do |method|
          break if authorized_in?(controller, method, method.name == action ? :action : :callback, 0, found)
        end
        found
      end

      # Adds the ways out in `method` that run before an authorize call to
      # `found`, statement by statement; whether `method` authorizes.
      # Callbacks and helpers here are called with no arguments, so their
      # optional parameters hold their defaults, and a branch on one that is
      # `true` always runs (Gumroad's `fetch_post(viewed_by_seller = true)`).
      def authorized_in?(controller, method, context, depth, found)
        locals = defaults(method)
        taken(body_statements(method.node.body), locals).any? do |statement|
          helper = depth < DEPTH && statement.is_a?(Prism::CallNode) && helper_call(controller, statement)
          next authorized_in?(controller, helper, context == :action ? :helper : context, depth + 1, found) if helper
          next true if authorizes?(controller, statement, 0)

          exit = exit_of(controller, statement, method, locals, context)
          found << exit if exit
          remember(statement, locals)
          false
        end
      end

      def defaults(method)
        optionals = method.node.parameters&.optionals || []
        optionals.to_h { |param| [param.name.to_s, [param.value, {}]] }
      end

      # The statements in order, with each branch that always runs read in
      # place of its `if`.
      def taken(statements, locals)
        statements.flat_map do |statement|
          inner = always_taken(statement, locals)
          inner ? taken(inner, locals) : [statement]
        end
      end

      # The statements of an `if` with no else whose condition is `true`, or
      # a local holding `true`.
      def always_taken(statement, locals)
        return nil unless statement.is_a?(Prism::IfNode) && statement.subsequent.nil?

        predicate = statement.predicate
        value = predicate.is_a?(Prism::LocalVariableReadNode) ? locals[predicate.name.to_s]&.first : predicate
        value.is_a?(Prism::TrueNode) ? body_statements(statement.statements) : nil
      end

      def remember(statement, locals)
        return unless statement.is_a?(Prism::LocalVariableWriteNode)

        locals[statement.name.to_s] = [statement.value, locals.dup]
      end

      # Whether a statement calls `authorize`, itself or through a helper.
      def authorizes?(controller, node, depth)
        calls(node).any? do |call|
          next true if AUTHORIZE.include?(call.name)

          helper = depth < DEPTH && @index.find_method(controller, call.name.to_s)
          helper ? helper_authorizes?(controller, helper, depth + 1) : false
        end
      end

      # Memoized per controller and helper; a helper that calls itself is
      # false while it is being read.
      def helper_authorizes?(controller, helper, depth)
        key = [controller, helper.owner, helper.name]
        return @authorizes.fetch(key) if @authorizes.key?(key)

        @authorizes[key] = false
        @authorizes[key] = authorizes?(controller, helper.node, depth)
      end

      # `e404 unless cond`, `if cond; head :forbidden; end` (no else) or
      # `cond || e404`.
      def exit_of(controller, statement, method, locals, context)
        case statement
        when Prism::IfNode, Prism::UnlessNode then guarded_exit(controller, statement, method, locals, context)
        when Prism::OrNode
          return nil unless leaves?(controller, statement.right, context, 0)

          Exit.new(condition: statement.left, negated: false, definition: method, locals: locals.dup,
                   location: location(method, statement))
        end
      end

      def helper_call(controller, node)
        return nil unless node.receiver.nil? && node.arguments.nil? && node.block.nil?

        @index.find_method(controller, node.name.to_s)
      end

      # `e404 unless cond` and `if cond; head :forbidden; end`, with no else.
      def guarded_exit(controller, node, method, locals, context)
        else_node = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        return nil if else_node
        return nil unless body_statements(node.statements).any? { |each| leaves?(controller, each, context, 0) }

        Exit.new(condition: node.predicate, negated: node.is_a?(Prism::IfNode), definition: method,
                 locals: locals.dup, location: location(method, node))
      end

      # Whether a statement ends the request in `context`: a raise, or a
      # helper whose body raises, anywhere; `return` in the action;
      # `redirect_to ... and return` in the action; and in a callback a
      # render or redirect, or a helper that makes one.
      def leaves?(controller, node, context, depth)
        case node
        when Prism::ReturnNode then returns?(node, context)
        when Prism::AndNode
          node.right.is_a?(Prism::ReturnNode) && (context == :action || leaves?(controller, node.left, context, depth))
        when Prism::CallNode then leaves_call?(controller, node, context, depth)
        else false
        end
      end

      # `return` ends the action; in a callback only `return head(...)` and
      # the like end the request.
      def returns?(node, context)
        context == :action || (context == :callback && halts?(node.arguments&.arguments&.first))
      end

      def leaves_call?(controller, node, context, depth)
        return false unless node.receiver.nil?
        return true if RAISES.include?(node.name) || (context == :callback && HALTS.include?(node.name))
        return false if depth >= DEPTH

        helper = @index.find_method(controller, node.name.to_s)
        !helper.nil? && body_statements(helper.node.body).any? { |each| leaves?(controller, each, context, depth + 1) }
      end

      def halts?(node) = node.is_a?(Prism::CallNode) && node.receiver.nil? && HALTS.include?(node.name)

      def body_statements(node)
        case node
        when Prism::StatementsNode then node.body
        when Prism::BeginNode then body_statements(node.statements)
        when nil then []
        else [node]
        end
      end

      def first_location(records)
        first = records.first
        first ? location(first[1], first[2]) : nil
      end

      def authorizations(action, records, loads)
        records.each_with_index.map { |record, at| authorization(action, record, loads.fetch(at)) }
      end

      def checked?(reach) = reach.any? { |method| calls(method.node).any? { |call| CHECKS.include?(call.name) } }

      def location(method, call) = "#{method.file}:#{call.location.start_line}"

      # The policy and rule an authorize call checks. Pundit: `authorize
      # record, :rule?, policy_class: P`; Action Policy: `authorize! record,
      # to: :rule?, with: P`; the rule defaults to the action's (`update?`).
      def authorization(action, record, load)
        _, method, call = record
        args = call.arguments&.arguments || []
        positional = args.grep_v(Prism::KeywordHashNode)
        rule = symbol(positional[1]) || symbol(keyword(args, :to)) || "#{action}?"
        policy = policy(args, positional[0], load)
        Authorization.new(policy: policy, rule: rule, location: location(method, call),
                          named_policy: (named_policy(positional[0]) unless policy))
      end

      # `@event` or `event`, alone or last in `[:admin, @event]`, names
      # EventPolicy (Admin::EventPolicy).
      def named_policy(target)
        record = target.is_a?(Prism::ArrayNode) ? target.elements.last : target
        return nil unless record.is_a?(Prism::InstanceVariableReadNode) || record.is_a?(Prism::LocalVariableReadNode)

        [*namespace(target), "#{camelize(record.name.to_s.delete_prefix("@"))}Policy"].join("::")
      end

      def policy(args, target, load)
        explicit = keyword(args, :policy_class) || keyword(args, :with)
        return explicit.slice.delete_prefix("::") if explicit && constant?(explicit)

        model = load.model
        return nil unless model

        [*namespace(target), "#{model}Policy"].join("::")
      end

      # Pundit's `authorize [:admin, record]` looks in Admin::.
      def namespace(target)
        return [] unless target.is_a?(Prism::ArrayNode)

        target.elements.take(target.elements.size - 1).filter_map { |part| symbol(part) }.map { |part| camelize(part) }
      end

      # A keyword argument's value node (`to: :update?`).
      def keyword(args, key)
        hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
        return nil unless hash.is_a?(Prism::KeywordHashNode)

        pair = hash.elements.find { |element| element.is_a?(Prism::AssocNode) && symbol(element.key) == key.to_s }
        pair.is_a?(Prism::AssocNode) ? pair.value : nil
      end

      def symbol(node)
        node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode) ? node.unescaped : nil
      end

      def camelize(word) = word.split("_").map(&:capitalize).join

      # The `before_action` callbacks that run for `action`, in order, then
      # the action itself.
      def run_methods(controller, action)
        names = []
        @index.callbacks(controller).each do |callback|
          next unless %i[before skip_before].include?(callback.kind) && @index.applies?(controller, callback, action)

          # Declaring a callback again moves it; skipping one removes it.
          names.delete_if { |name| callback.names.include?(name) }
          add_callback(names, callback) if callback.kind == :before
        end
        (names + [action]).filter_map { |name| @index.find_method(controller, name) }
      end

      def add_callback(names, callback)
        return names.concat(callback.names) unless callback.prepend

        callback.names.reverse_each { |name| names.unshift(name) }
      end

      # The methods that run, plus the controller's own helpers they call
      # with no arguments, followed DEPTH levels down.
      def reachable(controller, methods)
        reach = methods.dup
        frontier = methods
        DEPTH.times do
          frontier = frontier.flat_map do |method|
            calls(method.node).filter_map do |call|
              helper = call.arguments.nil? && @index.find_method(controller, call.name.to_s)
              helper if helper && !reach.include?(helper)
            end
          end.uniq
          reach.concat(frontier)
        end
        reach
      end

      # Every receiverless call under a node, in source order.
      def calls(node)
        found = []
        stack = [node]
        while (current = stack.shift)
          found << current if current.is_a?(Prism::CallNode) && current.receiver.nil?
          current.compact_child_nodes.reverse_each { |child| stack.unshift(child) }
        end
        found
      end

      # Each record an authorize call in `reach` checks, with the method and
      # the call.
      def records_in(reach)
        found = []
        reach.each do |method|
          calls(method.node).each do |call|
            record = AUTHORIZE.include?(call.name) && record_of(call)
            found << [record, method, call] if record
          end
        end
        found
      end

      # The record an authorize call checks: its first positional argument,
      # the last element of Pundit's `[:admin, record]`, never a class or a
      # name (`authorize Link`, `authorize :dashboard`).
      def record_of(call)
        node = (call.arguments&.arguments || []).find { |arg| !arg.is_a?(Prism::KeywordHashNode) }
        node = node.elements.last if node.is_a?(Prism::ArrayNode)
        return nil if node.nil? || constant?(node) || node.is_a?(Prism::SymbolNode)

        node
      end

      # How a value was loaded: its receiver chain's root decides, and names
      # the model when it is a class. `reach` is the methods that run for the
      # entry point, where an instance variable's assignments are looked for.
      def classify(controller, node, method, reach, depth)
        return unknown if depth > DEPTH

        case node
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          Load.new(kind: :unscoped, model: node.slice.delete_prefix("::"))
        when Prism::LocalVariableReadNode
          found = writes(method.node, LOCAL_WRITES, node.name).map { |value| [value, method] }
          classify_all(controller, found, reach, depth)
        when Prism::InstanceVariableReadNode
          found = reach.flat_map { |each| writes(each.node, IVAR_WRITES, node.name).map { |value| [value, each] } }
          classify_all(controller, found, reach, depth)
        when Prism::ParenthesesNode then classify_statements(controller, node.body, method, reach, depth)
        when Prism::OrNode then classify_or(controller, node, method, reach, depth)
        when Prism::CallNode then classify_call(controller, node, method, reach, depth)
        else unknown
        end
      end

      def unknown = Load.new(kind: :unknown, model: nil)

      # `Link.find_by(...) || e404`: a receiverless call on the right is a
      # way out (a 404, a redirect), not a second way to load the record.
      def classify_or(controller, node, method, reach, depth)
        left = classify(controller, node.left, method, reach, depth + 1)
        right = node.right
        return left if right.is_a?(Prism::CallNode) && right.receiver.nil?

        combine([left, classify(controller, right, method, reach, depth + 1)])
      end

      def classify_call(controller, node, method, reach, depth)
        receiver = node.receiver
        if receiver
          return Load.new(kind: :scoped, model: association(node.name.to_s)) if tenant_reader?(receiver)

          inner = classify(controller, receiver, method, reach, depth + 1)
          return scoped_by_keyword?(node, inner.model) ? Load.new(kind: :scoped, model: inner.model) : inner
        end
        return Load.new(kind: :scoped, model: nil) if tenant_reader?(node)

        helper = node.arguments.nil? && @index.find_method(controller, node.name.to_s)
        helper ? classify_statements(controller, helper.node.body, helper, reach, depth + 1) : unknown
      end

      # `Link.fetch(id, user: current_seller)` or `Link.where(user_id:
      # current_seller.id)`: the keyword is the resource's tenant (`tenant:
      # :user` in the mapping) and its value the current tenant.
      def scoped_by_keyword?(node, model)
        key = model && @tenant_keys[model]
        return false unless key

        hash = (node.arguments&.arguments || []).grep(Prism::KeywordHashNode).first
        return false unless hash.is_a?(Prism::KeywordHashNode)

        hash.elements.grep(Prism::AssocNode).any? { |pair| tenant_pair?(pair, key) }
      end

      def tenant_pair?(pair, key)
        name = symbol(pair.key)
        value = pair.value
        return tenant_reader?(value) if name == key
        return false unless name == "#{key}_id" && value.is_a?(Prism::CallNode)

        value.name == :id && tenant_reader?(value.receiver)
      end

      def tenant_reader?(node)
        node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name.to_s == @tenant_reader
      end

      # The mapped resource an association of the current tenant holds, by
      # Rails' naming (`links` holds Link), or nil (Gumroad's `products`).
      def association(name)
        singular = if name.end_with?("ies") then "#{name.delete_suffix("ies")}y"
                   else name.delete_suffix("s")
                   end
        model = camelize(singular)
        @resources.include?(model) ? model : nil
      end

      # A body's value: its last statement (`@link ||= Link.find(...)` reads
      # as what it assigns).
      def classify_statements(controller, body, method, reach, depth)
        last = body.is_a?(Prism::StatementsNode) ? body.body.last : body
        last = last.value if last.is_a?(Prism::InstanceVariableOrWriteNode) || last.is_a?(Prism::LocalVariableWriteNode)
        last ? classify(controller, last, method, reach, depth) : unknown
      end

      # Each value with the method it was assigned in.
      def classify_all(controller, found, reach, depth)
        return unknown if found.empty?

        combine(found.map { |value, method| classify(controller, value, method, reach, depth + 1) })
      end

      # The values assigned to a variable under a node, by `=` or `||=`.
      def writes(node, kinds, name)
        found = []
        stack = [node]
        while (current = stack.shift)
          case current
          when Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::InstanceVariableWriteNode,
               Prism::InstanceVariableOrWriteNode
            found << current.value if kinds.include?(current.class) && current.name == name
          end
          stack.concat(current.compact_child_nodes)
        end
        found
      end

      # Scoped only when every way the record was loaded is scoped; a model
      # only when every way names the same one.
      def combine(loads)
        kinds = loads.map(&:kind)
        kind = if kinds.all?(:scoped) then :scoped
               else kinds.include?(:unscoped) ? :unscoped : :unknown
               end
        models = loads.map(&:model).uniq
        Load.new(kind: kind, model: models.size == 1 ? models.first : nil)
      end

      # Whether `verify_authorized` runs after `action`: required when an
      # `after_action` names it for the action and no later skip removes it;
      # skipped when the app declares it but not for this action; nil when
      # the app never declares it.
      def verify(controller, action)
        callbacks = @index.callbacks(controller).select { |callback| callback.names.include?(VERIFY) }
        return nil if callbacks.empty?

        state = :skipped
        callbacks.each do |callback|
          next unless @index.applies?(controller, callback, action)

          state = callback.kind == :after ? :required : :skipped if %i[after skip_after].include?(callback.kind)
        end
        state
      end

      def constant?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
    end
  end
end
