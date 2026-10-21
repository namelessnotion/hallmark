# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # Reads a Rails app's routes from `config/routes.rb`, and the files it
    # `draw`s from `config/routes/`, with Prism, never loading the app: each
    # route as a `Route` ("EventsController#ledger", "GET", with its path),
    # for a run with no recorded routes (a code-only run). `Ops` reads their
    # verbs.
    #
    # Read: `get`, `post`, `put`, `patch`, `delete`, `match ..., via:` and
    # `root`, with `to: "controller#action"`, `controller:`, `action:`, the
    # `"path" => "controller#action"` form, or a bare name inside a
    # controller's scope (`get :ledger` in `resources :events do`);
    # `resources` and `resource` with `only:`, `except:`, `controller:`,
    # `module:` and `path:`; `namespace`, `scope` (`module:`, `controller:`,
    # `path:`), `controller :name do`, `member`, `collection`, `concern` and
    # `concerns`, and `draw`. Any other block is read as if it were not
    # there (`constraints`, `authenticate`, `devise_scope`, an `if`).
    # Redirects, mounted engines and routes built in a loop are skipped.
    #
    # Paths are approximate (a nested resource's parameter is its name
    # without a trailing "s"). Controller names are camelized with the
    # acronyms the app's initializers declare (`inflect.acronym
    # "ActivityPub"`), and no other inflection.
    class RoutesFile
      FILE = "config/routes.rb"
      DRAWN = "config/routes"
      INITIALIZERS = "config/initializers"
      VERBS = %w[get post put patch delete].freeze
      PLURAL = %w[index create new edit show update destroy].freeze
      SINGULAR = %w[create new edit show update destroy].freeze
      # Calls whose block holds routes of the same controller.
      SAME_SCOPE = %w[member collection new].freeze
      SKIPPED = %w[mount devise_for direct resolve use_doorkeeper].freeze

      # Where a route is defined: the controller modules around it
      # (`namespace :admin` gives "admin"), its path so far, the controller
      # a bare name belongs to (inside `resources :events`, "events"), and
      # the path a nested route adds (`/:event_id`) or a member route adds
      # (`/:id`).
      Scope = Struct.new(:modules, :path, :controller, :nested, :member, keyword_init: true) do
        def under(modules: self.modules, path: self.path, controller: self.controller, nested: "", member: "")
          Scope.new(modules: modules, path: path, controller: controller, nested: nested, member: member)
        end
      end

      attr_reader :routes

      def initialize(root)
        @root = File.expand_path(root)
        @routes = []
        @concerns = {}
        @drawn = []
        @acronyms = acronyms
        path = File.join(@root, FILE)
        read(path, Scope.new(modules: [], path: "", controller: nil, nested: "", member: "")) if File.file?(path)
      end

      private

      # `inflect.acronym "ActivityPub"` in an initializer: "activitypub" =>
      # "ActivityPub".
      def acronyms
        found = {}
        Dir.glob(File.join(@root, INITIALIZERS, "*.rb")).each do |path|
          source = File.read(path)
          next unless source.include?("acronym")

          collect_acronyms(Prism.parse(source).value, found)
        end
        found
      end

      def collect_acronyms(node, found)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::CallNode) && node.name == :acronym && (word = string(node.arguments&.arguments&.first))
          found[word.downcase] = word
        end
        node.compact_child_nodes.each { |child| collect_acronyms(child, found) }
      end

      def read(path, scope)
        return if @drawn.include?(path)

        @drawn << path
        walk(Prism.parse_file(path).value, scope)
      end

      def walk(node, scope)
        case node
        when Prism::CallNode then node.receiver.nil? ? call(node, scope) : walk(node.block, scope)
        when Prism::Node then node.compact_child_nodes.each { |child| walk(child, scope) }
        end
      end

      def call(node, scope)
        name = node.name.to_s
        args = node.arguments&.arguments || []
        case name
        when *VERBS then route(args, [name.upcase], scope)
        when "match" then route(args, via(args), scope)
        when "root" then root(args, scope)
        when "resources", "resource" then resources(node, args, scope, plural: name == "resources")
        when "namespace" then namespace(node, args, scope)
        when "scope" then scoped(node, args, scope)
        when "controller" then controller_scope(node, args, scope)
        else block_call(name, node, args, scope)
        end
      end

      # Calls that only group routes, or define or reuse a group.
      def block_call(name, node, args, scope)
        case name
        when *SAME_SCOPE then walk(node.block, scope.under(path: scope.path + (name == "member" ? scope.member : "")))
        when "concern" then concern(node, args)
        when "concerns" then names(args).each { |concern| walk(@concerns[concern], scope) }
        when "draw" then draw(args, scope)
        when *SKIPPED then nil
        else walk(node.block, scope)
        end
      end

      # One route. `to:` (or the value of `"path" => "c#a"`) names the
      # controller and action; else `controller:` and `action:`, else the
      # path names the action within the scope's controller, or both at the
      # top level (`get "photos/search"` is photos#search).
      def route(args, verbs, scope)
        written = written(args)
        return unless written

        path, target = written
        controller, action = target_of(target, path, args, scope)
        return unless controller && action

        verbs.each { |verb| add(scope, controller, action, verb, path ? "/#{path.delete_prefix("/")}" : "/#{action}") }
      end

      # The path a route is written with and its target, when it has one
      # (`to: "events#index"`); nil when the target is not a string (a
      # redirect).
      def written(args)
        if (pair = rocket(args))
          target = string(pair.value)
          return target && [string(pair.key), target]
        end

        path = string(args.grep_v(Prism::KeywordHashNode).first)
        to = keyword(args, "to")
        return [path, nil] unless to

        target = string(to)
        target && [path, target]
      end

      def target_of(target, path, args, scope)
        return target.split("#", 2) if target&.include?("#")

        controller = string(keyword(args, "controller")) || scope.controller
        action = string(keyword(args, "action"))
        action ? [controller, action] : bare_target(path&.delete_prefix("/"), controller)
      end

      # `get :ledger` in a controller's scope; `get "photos/search"`
      # (photos#search) outside one.
      def bare_target(path, controller)
        return nil unless path&.match?(%r{\A\w+(/\w+)*\z})

        parts = path.split("/")
        return parts.size == 1 ? [controller, path] : nil if controller

        [parts.take(parts.size - 1).join("/"), parts.last] if parts.size > 1
      end

      def root(args, scope)
        target = string(args.grep_v(Prism::KeywordHashNode).first) || string(keyword(args, "to"))
        controller, action =
          if target&.include?("#")
            target.split("#", 2)
          else
            [string(keyword(args, "controller")), string(keyword(args, "action"))]
          end
        add(scope, controller, action, "GET", "/") if controller && action
      end

      def resources(node, args, scope, plural:)
        module_name = string(keyword(args, "module"))
        outer = scope.under(modules: module_name ? scope.modules + [module_name] : scope.modules,
                            path: scope.path + scope.nested, controller: nil)
        names(args).each { |name| resource(node, name, args, outer, plural: plural) }
      end

      def resource(node, name, args, scope, plural:)
        controller = string(keyword(args, "controller")) || (plural ? name : plural_of(name))
        inner = scope.under(path: "#{scope.path}/#{string(keyword(args, "path")) || name}".squeeze("/"),
                            controller: controller)
        default_actions(args, plural).each { |action| default_route(inner, action, plural: plural) }
        # In the block, a bare route is nested (`/events/:event_id/ledger`)
        # and a member route is on one record (`/events/:id/cancel`).
        inner = inner.under(nested: "/:#{singular_of(name)}_id", member: "/:id") if plural
        names_of(keyword(args, "concerns"))&.each { |concern| walk(@concerns[concern], inner) }
        walk(node.block, inner)
      end

      def default_actions(args, plural)
        (names_of(keyword(args, "only")) || (plural ? PLURAL : SINGULAR)) - (names_of(keyword(args, "except")) || [])
      end

      def default_route(scope, action, plural:)
        return unless (controller = scope.controller)

        verbs = case action
                when "create" then %w[POST]
                when "update" then %w[PATCH PUT]
                when "destroy" then %w[DELETE]
                else %w[GET]
                end
        id = plural && %w[show edit update destroy].include?(action) ? "/:id" : ""
        suffix = %w[new edit].include?(action) ? "/#{action}" : ""
        verbs.each { |verb| add(scope, controller, action, verb, "#{id}#{suffix}") }
      end

      def namespace(node, args, scope)
        name = names(args).first
        return walk(node.block, scope) unless name

        module_name = string(keyword(args, "module")) || name
        path = string(keyword(args, "path")) || name
        walk(node.block, scope.under(modules: scope.modules + [module_name],
                                     path: "#{scope.path}#{scope.nested}/#{path}".squeeze("/"), controller: nil))
      end

      def scoped(node, args, scope)
        module_name = string(keyword(args, "module"))
        path = string(args.grep_v(Prism::KeywordHashNode).first) || string(keyword(args, "path"))
        walk(node.block, scope.under(modules: module_name ? scope.modules + [module_name] : scope.modules,
                                     path: "#{scope.path}#{scope.nested}#{"/#{path}" if path}".squeeze("/"),
                                     controller: string(keyword(args, "controller")) || scope.controller))
      end

      def controller_scope(node, args, scope)
        name = names(args).first
        walk(node.block, name ? scope.under(controller: name) : scope)
      end

      def concern(node, args)
        name = names(args).first
        block = node.block
        @concerns[name] = block if name && block
      end

      def draw(args, scope)
        name = names(args).first
        return unless name

        path = File.join(@root, DRAWN, "#{name}.rb")
        read(path, scope) if File.file?(path)
      end

      # "payroll/positions" in module "admin" is Admin::Payroll::PositionsController.
      def add(scope, controller, action, verb, path)
        full = controller.start_with?("/") ? controller.delete_prefix("/") : [*scope.modules, controller].join("/")
        name = full.split("/").map { |part| part.split("_").map { |word| @acronyms[word] || word.capitalize }.join }
                   .join("::")
        @routes << Route.new(entry_point: "#{name}Controller##{action}", verb: verb,
                             path: "#{scope.path}#{scope.nested}#{path}".squeeze("/"))
      end

      def via(args)
        verbs = names_of(keyword(args, "via")) || []
        return [""] if verbs.empty? || verbs.include?("all")

        verbs.map(&:upcase)
      end

      def rocket(args)
        hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
        return nil unless hash.is_a?(Prism::KeywordHashNode)

        pair = hash.elements.find { |element| element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::StringNode) }
        pair.is_a?(Prism::AssocNode) ? pair : nil
      end

      def keyword(args, key)
        hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
        return nil unless hash.is_a?(Prism::KeywordHashNode)

        pair = hash.elements.find { |element| element.is_a?(Prism::AssocNode) && symbol(element.key) == key }
        pair.is_a?(Prism::AssocNode) ? pair.value : nil
      end

      # The symbol and string arguments: `resources :events, :tags`.
      def names(args) = args.filter_map { |arg| symbol(arg) || string(arg) }

      # `only: :show`, `only: [:index, :show]` or `only: []`; nil when absent
      # or not a literal.
      def names_of(node)
        case node
        when Prism::ArrayNode then node.elements.filter_map { |element| symbol(element) || string(element) }
        when Prism::SymbolNode, Prism::StringNode then [node.unescaped]
        end
      end

      def symbol(node) = node.is_a?(Prism::SymbolNode) ? node.unescaped : nil
      def string(node) = node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode) ? node.unescaped : nil

      def plural_of(name)
        return "#{name}es" if name.match?(/(x|z|ch|sh|ss)\z/)
        return name if name.end_with?("s")
        return "#{name.delete_suffix("y")}ies" if name.match?(/[^aeiou]y\z/)

        "#{name}s"
      end

      def singular_of(name)
        return "#{name.delete_suffix("ies")}y" if name.end_with?("ies")

        name.delete_suffix("s")
      end
    end
  end
end
