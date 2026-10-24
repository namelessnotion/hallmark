# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # The revocation lint (R1, threat 9; phase 3 step 9): a role read on
    # the path of the mapping's role readers, a `term` or a rule body that
    # goes through a cache outliving a request (`Rails.cache`, the session
    # or cookies, token claims, a class-level memo), where no callback on
    # the membership, principal or tenant class clears it.
    #
    # It reads call graphs, not guards. From each start point (the
    # mapping's `principal ..., roles:` and `tenant ..., roles_in:` readers,
    # each `term` source, each rule body and DeclarativePolicy condition the
    # extractor read), it follows calls whose receiver it can type: the user
    # (the principal class), the tenant parameter, `self` or no receiver
    # (the method's own class), an association a model declares
    # (`belongs_to :seller, class_name: "User"`) and a constant's class
    # methods; at most DEPTH calls deep, each method once. Model code is
    # read lazily, one file per class by Zeitwerk's naming, with included,
    # prepended and parent classes as the walk needs them. A call on a
    # typed receiver whose method no index holds (GitLab's `lib/`), or on a
    # constant no index holds, stops the walk and is listed (`unread`); a
    # call on a value Hallmark cannot type (a local, a chain) is not
    # followed and not listed.
    #
    # Per-request and per-object stores are not caches: instance-variable
    # memos in instance methods, `strong_memoize`, `RequestStore`,
    # GitLab's SafeRequestStore and SafeRequestLoader, `Current`
    # attributes and DeclarativePolicy's condition cache have no shape
    # here, and denormalized tables are data (role_reads/caches.rb).
    class RoleReads
      DIRS = %w[app/models app/models/concerns ee/app/models ee/app/models/concerns].freeze
      DEPTH = 4

      # Where a walk starts: its label as the lint prints it, and the
      # methods it walked, in order.
      Start = Struct.new(:label, :walked, keyword_init: true) do
        def to_s = label
      end

      # Where translation is: the class whose code it is (nil in a `term`),
      # whether in a class method, the names bound to classes, the file,
      # the path from the start and the depth.
      Frame = Struct.new(:klass, :singleton, :env, :file, :path, :depth, :start, keyword_init: true)

      # A call the walk could not follow, with where it is (the start's
      # label for a term or a reader) and the start that first reached it.
      Unread = Struct.new(:call, :location, :start, keyword_init: true) do
        def to_s = location == start ? "#{call}, from #{start}" : "#{call} (#{location}), from #{start}"
      end

      # A role read cached on purpose (`cache_ok`): the method holding it,
      # where, and why.
      Accepted = Struct.new(:holder, :location, :reason, keyword_init: true) do
        def to_s = "#{holder} (#{location}): #{reason}"
      end

      # Methods every Ruby or Active Record object answers, never followed
      # or listed.
      PLAIN = %w[id == != ! present? blank? nil? include? any? none? empty? map each select reject find where
                 find_by exists? pluck first last count size to_s to_a to_sym to_i is_a? kind_of? respond_to?
                 send public_send try new build create update save reload persisted? new_record? destroyed?
                 read_attribute [] in? to_h keys values freeze dup tap then presence class flat_map uniq sort
                 join compact order limit includes joins merge or not all none ids filter_map sum raise fail
                 lambda proc loop puts p format Array Integer String Hash block_given? allowed_to? check? can?
                 cannot? allow! deny! authorize! strong_memoize strong_memoize_with super].freeze

      ASSOCIATIONS = %i[belongs_to has_one has_many has_and_belongs_to_many].freeze

      attr_reader :starts, :caches, :unread, :accepted

      def initialize(mapping, root, policies:, rules:)
        @mapping = mapping
        @root = root
        @policies = policies
        @models = SourceIndex.new(root, [])
        @loaded = Set.new
        @associations = {}
        @visited = {}
        @starts = []
        @caches = []
        @unread = []
        @accepted = []
        @quiet = false
        read_starts(rules)
        validate_accepted!
        judge
      end

      # The R1 lints: caches no callback clears and no `cache_ok` accepts.
      def lints
        @caches.reject { |cache| cache.cleared || cache.accepted }.map do |cache|
          DeclarativeTranslator::Lint.new(kind: "R1", location: cache.location, message: cache.message)
        end
      end

      # The class a model or policy name is indexed under, loading its file
      # (and its ancestors') on first use; nil when no index holds it.
      def index_for(name)
        return nil unless name
        return @policies if @policies.scopes.key?(name)

        load_class(name)
        @models.scopes.key?(name) ? @models : nil
      end

      # A method of an indexed class, instance or class (`self.x`).
      def find_method(klass, name) = klass ? index_for(klass)&.find_method(klass, name) : nil

      # The class an association a model declares names; nil for a
      # collection (`has_many`), a polymorphic one or an unknown name.
      def association(klass, name) = associations(klass)[name]

      # Whether a name is data on the class: an association of any kind
      # (collections included) or an attribute reader, read, not followed.
      def data?(klass, name) = associations(klass).key?(name) || attribute?(klass, name)

      private

      def principal = @mapping.principal_name
      def tenant_class = @mapping.tenancy&.name

      def frame(klass, env, start, file)
        Frame.new(klass: klass, singleton: false, env: env, file: file, path: [], depth: 0, start: start)
      end

      # Walks one method of `klass`, called at `site`, binding its leading
      # parameters to `bind` (class names, nil for unknown).
      def visit(klass, name, caller, site:, bind: [], method: nil)
        method ||= find_method(klass, name)
        return unfound(klass, name, caller, site, bind) unless method

        depth = caller.depth + (caller.path.empty? ? 0 : 1)
        key = "#{method.owner}##{method.name}"
        return if depth > DEPTH || @visited.fetch(key, DEPTH + 1) <= depth

        @visited[key] = depth
        label = method_label(method.owner, method.name)
        caller.start.walked << label
        env = callee_env(klass, method, caller, bind)
        inner = Frame.new(klass: klass, singleton: method.name.start_with?("self."), env: env, file: method.file,
                          path: caller.path + [label], depth: depth, start: caller.start)
        scan(method.node.body, inner, method: method)
      end

      # A method the class does not define: followed where a `delegate`
      # sends it, else listed.
      def unfound(klass, name, caller, site, bind)
        target = delegated(klass, name)
        return visit(target[0], target[1], caller, site: site, bind: bind) if target

        not_followed(method_label(klass, name), site, caller)
      end

      # Lists a call the walk could not follow, once, unless the clearing
      # search is the one walking.
      def not_followed(call, site, frame)
        return nil if @quiet || @unread.any? { |each| each.call == call }

        @unread << Unread.new(call: call, location: site, start: frame.start.label)
        nil
      end

      # Where a call is: file and line, or the start's label in a term or
      # a reader named in the mapping (no file of its own).
      def site_of(node, frame) = frame.file.empty? ? frame.start.label : "#{frame.file}:#{node.location.start_line}"

      # The names a method's body binds: its parameters, and in app/policies
      # the user as policies read it (a policy's own helper also keeps the
      # record's names).
      def callee_env(klass, method, caller, bind)
        env = parameter_names(method.node).zip(bind).to_h.compact
        return env unless klass && @policies.scopes.key?(klass)

        user_env.merge(caller.klass == klass ? caller.env : {}).merge(env)
      end

      def method_label(klass, name)
        name.start_with?("self.") ? "#{klass}.#{name.delete_prefix("self.")}" : "#{klass}##{name}"
      end

      # Every node under `node`, nested `def`s left out, depth first.
      def each_node(node, &block)
        return unless node

        stack = [node]
        while (current = stack.pop)
          block.call(current)
          current.compact_child_nodes.reverse_each { |child| stack << child unless child.is_a?(Prism::DefNode) }
        end
      end

      # Reads one body: the caches in it, then the calls it makes.
      def scan(node, frame, method: nil)
        return unless node

        locals = locals_of(node, frame)
        typed = {}
        locals.each { |name, value| typed[name] = value if value.is_a?(String) }
        frame.env = frame.env.merge(typed)
        detect_caches(node, frame, method, locals)
        each_node(node) { |child| follow(child, frame) if child.is_a?(Prism::CallNode) }
      end

      # Locals assigned in the body: the class each holds when it can be
      # typed (a String), else the node assigned, for keys.
      def locals_of(node, frame)
        locals = {}
        each_node(node) do |child|
          next unless child.is_a?(Prism::LocalVariableWriteNode)

          name = child.name.to_s
          locals[name] ||= class_of(child.value, frame) || child.value
        end
        locals
      end

      def follow(call, frame)
        target = callee(call, frame)
        return unless target

        klass, name = target
        visit(klass, name, frame, site: site_of(call, frame), bind: call_classes(call, frame))
      end

      # The class and method a call reaches, or nil when the walk does not
      # follow it (an untyped receiver, a reader the frame binds, a plain
      # Ruby method); a constant no index holds is listed.
      def callee(call, frame)
        name = call.name.to_s
        receiver = call.receiver
        return nil if PLAIN.include?(name) || name.end_with?("=")

        case receiver
        when nil, Prism::SelfNode then own_callee(call, frame, name)
        when Prism::ConstantReadNode, Prism::ConstantPathNode then constant_callee(receiver, frame, name)
        else
          klass = class_of(receiver, frame)
          klass && !data?(klass, name) ? [klass, name] : nil
        end
      end

      def own_callee(call, frame, name)
        klass = frame.klass
        return nil if klass.nil? || (call.arguments.nil? && frame.env.key?(name))
        return nil if data?(klass, name)
        return [klass, "self.#{name}"] if frame.singleton && find_method(klass, "self.#{name}")

        [klass, name]
      end

      def constant_callee(receiver, frame, name)
        constant = receiver.slice.delete_prefix("::")
        return nil if Caches::NOT_CACHES.include?(constant) || Caches::FRAMEWORK.include?(constant)

        klass = resolve_constant(constant, frame)
        return not_followed("#{constant}.#{name}", site_of(receiver, frame), frame) unless
          klass && index_for(klass)

        find_method(klass, "self.#{name}") ? [klass, "self.#{name}"] : nil
      end

      # A constant as written in the frame's class, resolved as Ruby
      # would, innermost namespace first; nil when no index holds it.
      def resolve_constant(name, frame) = resolve_in(name, frame.klass)

      def resolve_in(name, klass)
        parts = klass.to_s.split("::")
        parts.size.downto(0) do |depth|
          candidate = [*parts.first(depth), name].join("::")
          return candidate if index_for(candidate)
        end
        nil
      end

      # The class each positional argument holds, for the callee's
      # parameters.
      def call_classes(call, frame)
        (call.arguments&.arguments || []).map { |arg| class_of(arg, frame) }
      end

      # The class a node holds, when the walk can tell: a name the frame
      # binds, `self`, or a single association of a known class.
      def class_of(node, frame)
        case node
        when Prism::SelfNode then frame.klass
        when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then frame.env[node.name.to_s]
        when Prism::CallNode then call_class(node, frame)
        end
      end

      def call_class(node, frame)
        name = node.name.to_s
        receiver = node.receiver
        if receiver.nil? || receiver.is_a?(Prism::SelfNode)
          return frame.env[name] if node.arguments.nil? && frame.env.key?(name)

          klass = frame.klass
          return klass && association(klass, name)
        end
        owner = class_of(receiver, frame)
        owner && association(owner, name)
      end

      # Whether a model declares the name as an attribute reader.
      def attribute?(klass, name)
        index = index_for(klass)
        return false unless index

        index.calls(klass).any? do |call|
          %i[attr_reader attr_accessor].include?(call.name) &&
            call.arguments.any? { |arg| arg.is_a?(Prism::SymbolNode) && arg.unescaped == name }
        end
      end

      def associations(klass) = @associations[klass] ||= read_associations(klass)

      # Every association a class declares, by name: its class for a single
      # record, nil for a collection or a polymorphic one.
      def read_associations(klass)
        index = index_for(klass)
        return {} unless index

        index.calls(klass).each_with_object({}) do |call, table|
          name = call.arguments.first
          next unless ASSOCIATIONS.include?(call.name) && name.is_a?(Prism::SymbolNode)

          single = %i[belongs_to has_one].include?(call.name)
          table[name.unescaped] ||= single ? association_class(call, name.unescaped) : nil
        end
      end

      def association_class(call, name)
        options = Caches.options(call.arguments)
        return nil if options["polymorphic"].is_a?(Prism::TrueNode)

        named = options["class_name"]
        named.is_a?(Prism::StringNode) ? named.unescaped.delete_prefix("::") : Caches.camelize(name)
      end

      # Parses a class's file under DIRS by Zeitwerk's naming, then its
      # included, prepended and parent classes', once each.
      def load_class(name)
        return if @loaded.include?(name)

        @loaded << name
        path = Caches.file_name(name)
        DIRS.each do |dir|
          file = File.join(@root, dir, "#{path}.rb")
          @models.add_file(file) if File.file?(file)
        end
        scope = @models.scopes[name]
        return unless scope

        (scope.includes + scope.prepends + [scope.superclass].compact).each do |ref|
          (candidates(ref, scope.namespace) + candidates(ref, scope.name.split("::"))).uniq.each do |candidate|
            load_class(candidate)
          end
        end
      end

      def candidates(ref, namespace)
        return [ref.delete_prefix("::")] if ref.start_with?("::")

        namespace.size.downto(0).map { |depth| [*namespace.first(depth), ref].join("::") }
      end

      def relative(file) = file.delete_prefix("#{@root}/")

      # Every `cache_ok` names a method the walk can find.
      def validate_accepted!
        @mapping.caches_ok.each_key do |key|
          klass, separator, name = key.rpartition(/[#.]/)
          method = find_method(klass, separator == "." ? "self.#{name}" : name)
          next if method

          raise ConfigurationError, "cache_ok #{key} names no method Hallmark can find in #{DIRS.first}, " \
                                    "its concerns or #{Extractor::DIRS.join(", ")}"
        end
      end
    end
  end
end

require_relative "role_reads/starts"
require_relative "role_reads/delegation"
require_relative "role_reads/caches"
require_relative "role_reads/clearing"
