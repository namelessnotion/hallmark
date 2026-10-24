# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # Reads Grape APIs under `lib/api` and `app/api` (phase 2 step 4), such
    # as GitLab's REST API, never loading them: each endpoint, named as the
    # Grape collector names it ("GET /projects/:id/pipeline_schedules": the
    # verb, then the `resource`, `namespace`, `group`, `segment` and
    # `route_param` paths around it and its own), and the abilities it
    # checks with `authorize!(:ability, subject)` or `can?(user, :ability,
    # subject)`, in its block or in the helpers it calls, with or without
    # arguments (GitLab's `user_project` calls `find_project!(id)`, which
    # checks `read_project`) (`helpers do`
    # blocks of its class, and modules named `*Helpers` under the API
    # directories).
    #
    # The subject is resolved to a mapped resource by its reader's name:
    # `user_project` is a Project, `pipeline_schedule` a Ci::PipelineSchedule
    # (the resource whose last name segment matches); the policy is the
    # resource's name plus `Policy`, as DeclarativePolicy finds it.
    #
    # Each endpoint also keeps what it presents (phase 3 step 8): `present
    # x, with: E, ...` and `present :key, x, with: E`, in its block and in
    # the helpers it calls, one level down with their parameters bound
    # (GitLab's `present_project(project, options = {})`), with `E`
    # resolved later through the API class's namespaces
    # (`Serializers::Rendering`).
    class GrapeEndpoints
      DIRS = %w[lib/api app/api].freeze
      VERBS = %i[get post put patch delete head options].freeze
      SCOPES = %i[resource resources namespace group segment].freeze
      DEPTH = 4

      # The API class an endpoint is in: its name, the namespaces its
      # constants resolve in, and its file.
      Api = Struct.new(:name, :namespace, :file, keyword_init: true)

      # One endpoint: its entry point name, where it is, and what it checks.
      Endpoint = Struct.new(:name, :location, :authorizations, :renderings, keyword_init: true) do
        def checked? = authorizations.any?
      end

      attr_reader :endpoints

      # Where the endpoint named `name` is defined, or nil.
      def location_of(name) = endpoint_named(name)&.location

      # The endpoint named `name`, or nil.
      def endpoint_named(name) = @endpoints.find { |endpoint| endpoint.name == name }

      # A helper an endpoint can call: its class's, else a global one; and
      # the file a global one is in.
      def helper(name, helpers) = helpers[name] || @global[name]
      def helper_file(name) = @global_files[name]

      def initialize(mapping, root)
        @resources = mapping.resources.keys
        @root = File.expand_path(root)
        @global = {}
        @global_files = {}
        @endpoints = []
        @api = Api.new(name: "", namespace: [], file: "")
        files = DIRS.flat_map { |dir| Dir.glob(File.join(@root, dir, "**", "*.rb")) }
        parsed = files.to_h { |path| [path, Prism.parse_file(path).value] }
        # Every file's global helpers first: an endpoint may call one defined in a later file.
        parsed.each_key { |path| collect_global_helpers(parsed.fetch(path), false, path.delete_prefix("#{@root}/")) }
        parsed.each { |path, tree| read_classes(tree, path.delete_prefix("#{@root}/")) }
      end

      private

      # Defs inside modules named `*Helpers` (GitLab's API::Helpers), which
      # every endpoint can call.
      def collect_global_helpers(node, inside, file)
        case node
        when Prism::ModuleNode
          name = node.constant_path.slice
          inside ||= name.end_with?("Helpers")
          node.compact_child_nodes.each { |child| collect_global_helpers(child, inside, file) }
        when Prism::DefNode then global_helper(node, file) if inside && node.receiver.nil?
        when Prism::Node then node.compact_child_nodes.each { |child| collect_global_helpers(child, inside, file) }
        end
      end

      def global_helper(node, file)
        @global[node.name.to_s] = node
        @global_files[node.name.to_s] = file
      end

      # Classes under a node, with the namespaces around them.
      def read_classes(node, file, namespace = [])
        case node
        when Prism::ClassNode then read_api(node, file, namespace + node.constant_path.slice.split("::"))
        when Prism::ModuleNode
          inner = namespace + node.constant_path.slice.split("::")
          node.compact_child_nodes.each { |child| read_classes(child, file, inner) }
        when Prism::Node then node.compact_child_nodes.each { |child| read_classes(child, file, namespace) }
        end
      end

      # A class body: its `helpers do` defs first, then its endpoints.
      def read_api(node, file, namespace)
        helpers = {}
        collect_helpers(node.body, helpers)
        @api = Api.new(name: namespace.join("::"), namespace: namespace, file: file)
        read_scope(node.body, [], helpers, file)
      end

      def collect_helpers(node, helpers)
        return unless node

        calls_with_blocks(node).each do |call|
          next unless call.name == :helpers

          body = block_body(call)
          defs = body.is_a?(Prism::StatementsNode) ? body.body.grep(Prism::DefNode) : []
          defs.each { |definition| helpers[definition.name.to_s] = definition }
        end
      end

      # Endpoints under a node, with the path segments around it.
      def read_scope(node, path, helpers, file)
        statements = node.is_a?(Prism::StatementsNode) ? node.body : []
        statements.grep(Prism::CallNode).each do |call|
          next unless call.receiver.nil?

          if VERBS.include?(call.name) && call.block.is_a?(Prism::BlockNode)
            endpoint(call, path, helpers, file)
          elsif (segment = segment_of(call))
            read_scope(block_body(call), path + [segment], helpers, file)
          end
        end
      end

      # The path a scoping call adds: `resource :projects`, `route_param :id`.
      def segment_of(call)
        return nil unless call.block.is_a?(Prism::BlockNode)

        name = name_arg(call)
        return nil unless name

        return ":#{name}" if call.name == :route_param
        return name if SCOPES.include?(call.name)

        nil
      end

      def endpoint(call, path, helpers, file)
        own = name_arg(call) || ""
        parts = (path + [own]).flat_map { |part| part.split("/") }.reject(&:empty?)
        name = "#{call.name.to_s.upcase} /#{parts.join("/")}"
        location = "#{file}:#{call.location.start_line}"
        found = checks(block_body(call), helpers, 0, [])
        authorizations = found.map do |ability, subject, line, via|
          Controllers::Authorization.new(policy: policy_for(subject), rule: ability, location: "#{file}:#{line}",
                                         subject: subject, via: via)
        end
        @endpoints << Endpoint.new(name: name, location: location, authorizations: authorizations.uniq,
                                   renderings: Presents.new(self, helpers, @api, authorizations.uniq)
                                                       .read(block_body(call)))
      end

      # The first argument when it is a Symbol or a String.
      def name_arg(call)
        first = call.arguments&.arguments&.first
        first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode) ? first.unescaped : nil
      end

      # [ability, subject reader, line, helper] for each check under a
      # node, through the helpers it calls; `helper` is the one the
      # endpoint block itself called, nil for a check in the block.
      def checks(node, helpers, depth, seen)
        return [] if node.nil? || depth > DEPTH

        calls(node).flat_map do |call|
          check = check_of(call, helpers)
          check ? [[*check, seen.first]] : helper_checks(call, helpers, depth, seen)
        end
      end

      def helper_checks(call, helpers, depth, seen)
        name = call.name.to_s
        helper = helper(name, helpers)
        return [] unless helper && !seen.include?(name)

        checks(helper.body, helpers, depth + 1, seen + [name])
      end

      def check_of(call, helpers)
        args = call.arguments&.arguments || []
        ability, subject = case call.name
                           when :authorize! then [args[0], args[1]]
                           when :can? then [args[1], args[2]]
                           end
        name = ability_name(ability, helpers)
        name ? [name, reader_of(subject), call.location.start_line] : nil
      end

      # A Symbol, or a helper that returns one (GitLab's
      # `read_project_ability`).
      def ability_name(node, helpers)
        return node.unescaped if node.is_a?(Prism::SymbolNode)
        return nil unless node.is_a?(Prism::CallNode) && node.receiver.nil? && node.arguments.nil?

        last = last_expression(helpers[node.name.to_s] || @global[node.name.to_s])
        last.is_a?(Prism::SymbolNode) ? last.unescaped : nil
      end

      # A helper's value: the last expression of its body, or nil.
      def last_expression(helper)
        body = helper&.body
        body.is_a?(Prism::StatementsNode) ? body.body.last : body
      end

      # The name of a receiverless reader (`user_project`) or a local
      # (`|pipeline_schedule|`), or nil.
      def reader_of(node)
        return node.name.to_s if node.is_a?(Prism::LocalVariableReadNode)

        node.is_a?(Prism::CallNode) && node.receiver.nil? && node.arguments.nil? ? node.name.to_s : nil
      end

      # The policy of the mapped resource a reader names, or nil.
      def policy_for(reader)
        return nil unless reader

        words = reader.split("_")
        words.size.times do |drop|
          model = words.drop(drop).map(&:capitalize).join
          found = @resources.find { |name| name == model || name.end_with?("::#{model}") }
          return "#{found}Policy" if found
        end
        nil
      end

      # Every receiverless call under a node.
      def calls(node)
        found = []
        stack = [node]
        while (current = stack.shift)
          found << current if current.is_a?(Prism::CallNode) && current.receiver.nil?
          current.compact_child_nodes.each { |child| stack << child }
        end
        found
      end

      def calls_with_blocks(node)
        calls(node).select { |call| call.block.is_a?(Prism::BlockNode) }
      end

      def block_body(call)
        block = call.block
        block.is_a?(Prism::BlockNode) ? block.body : nil
      end
    end
  end
end
