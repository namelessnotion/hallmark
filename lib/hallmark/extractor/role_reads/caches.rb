# typed: strict
# frozen_string_literal: true

module Hallmark
  class Extractor
    # The revocation lint's cache shapes and key templates (role_reads.rb).
    class RoleReads
      # A role read kept somewhere that outlives a request, found on a walk:
      # its shape (`Rails.cache.fetch`, `session[...]`, `cookies.encrypted[...]`,
      # token claims, a class-level memo), its key as a template (a
      # string's interpolations as `{}`, an Array's parts joined with `/`, a
      # method call as `Class#name()`), any `expires_in:` as written, the
      # method holding it, where it is, the start and path that reached it,
      # the class whose code it is, the classes whose `updated_at` (or cache
      # key or version) the key interpolates, and once judged what clears
      # it, whether `cache_ok` accepts it and which classes' callbacks were
      # searched.
      Cache = Struct.new(:shape, :key, :expires_in, :holder, :location, :start, :path, :owner, :versions, :cleared,
                         :accepted, :searched, keyword_init: true) do
        # Session cookies and token claims hold copies no model callback reaches.
        def clearable? = shape.start_with?("Rails.cache") || shape.start_with?("class-level memo")

        # The start, then the methods walked (a rule's own method once).
        def walked = [start, *(path.first == start ? path.drop(1) : path)].join(" -> ")

        def described
          parts = [("key #{key.inspect}" if key), ("expires_in: #{expires_in}" if expires_in)].compact
          "`#{shape}`#{" (#{parts.join(", ")})" unless parts.empty?}"
        end

        def message
          why = if clearable?
                  "and no callback clears it when a membership changes (searched #{searched.join(", ")})"
                else
                  "a copy no model callback can clear"
                end
          bounded = expires_in ? "; `expires_in:` bounds the staleness but does not clear it" : ""
          "role read through #{described} outlives the request, #{why}#{bounded}; reached from #{walked}"
        end

        def to_s
          state = if accepted then "accepted (cache_ok: #{accepted})"
                  elsif cleared then "cleared #{cleared}"
                  else "not cleared (R1)"
                  end
          "#{described} in #{holder} (#{location}): #{state}"
        end
      end

      # Helpers shared by the walk and the clearing search.
      module Caches
        # Stores that live for a request or an object: their reads are not
        # caches, and their calls are not followed or listed.
        NOT_CACHES = %w[RequestStore Gitlab::SafeRequestStore Gitlab::SafeRequestLoader Current].freeze
        # Library and core constants whose calls the walk neither follows
        # nor lists (`Rails.cache` and `JWT.decode` are shapes of their own).
        FRAMEWORK = %w[Rails ActiveRecord ActiveSupport I18n Time Date DateTime JSON JWT JSON::JWT Integer Array
                       Hash String Set URI Kernel Struct Regexp SecureRandom Digest OpenSSL BigDecimal Float Math
                       Base64 File Dir Logger Feature Flipper].freeze
        CLAIMS = %w[claims payload decoded_token].freeze
        READS = %i[fetch read read_multi fetch_multi].freeze
        STORES = %i[session cookies].freeze
        JARS = %i[signed encrypted permanent].freeze
        # What a key interpolates to stay fresh when its object is touched.
        VERSIONS = %w[updated_at cache_key cache_key_with_version cache_version].freeze

        # A call's keyword arguments by name, as nodes.
        def self.options(args)
          hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode) }
          return {} unless hash.is_a?(Prism::KeywordHashNode) || hash.is_a?(Prism::HashNode)

          hash.elements.each_with_object({}) do |element, out|
            key = element.is_a?(Prism::AssocNode) ? element.key : nil
            out[key.unescaped] = element.value if key.is_a?(Prism::SymbolNode)
          end
        end

        # "team_membership" -> "TeamMembership"
        def self.camelize(name) = name.split("_").map(&:capitalize).join

        # A class's file under a Zeitwerk root: User::Team -> "user/team".
        def self.file_name(class_name)
          class_name.split("::").map do |part|
            part.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
          end.join("/")
        end

        def self.rails?(node)
          return node.name == :Rails if node.is_a?(Prism::ConstantReadNode)

          node.is_a?(Prism::ConstantPathNode) ? node.slice == "::Rails" : false
        end

        # `Rails.cache`, written out.
        def self.rails_cache_call?(node)
          return false unless node.is_a?(Prism::CallNode) && node.name == :cache && node.arguments.nil?

          rails?(node.receiver)
        end

        def self.jwt_decode?(node)
          return false unless node.is_a?(Prism::CallNode) && node.name == :decode

          receiver = node.receiver
          receiver ? %w[JWT ::JWT JSON::JWT ::JSON::JWT].include?(receiver.slice) : false
        end

        def self.empty_value?(node)
          case node
          when Prism::NilNode then true
          when Prism::HashNode, Prism::ArrayNode then node.elements.empty?
          else false
          end
        end
      end

      private

      # The caches in one body, attributed to `method` (nil for a lambda or
      # a term, attributed to its start).
      def detect_caches(node, frame, method, locals)
        holder = method ? method_label(method.owner, method.name) : frame.start.label
        nodes = []
        each_node(node) { |child| nodes << child }
        calls = nodes.grep(Prism::CallNode)
        calls.each { |call| store_cache(call, frame, holder, locals) || rails_cache(call, frame, holder, locals) }
        token_caches(calls, frame, holder, locals)
        return unless frame.singleton && method

        nodes.each { |child| memo_cache(child, frame, holder, method) }
      end

      # Role reads from token claims, else the decoding itself.
      def token_caches(calls, frame, holder, locals)
        claims = calls.select { |call| claim_read?(call, locals) }
        reads = claims.empty? ? calls.select { |call| Caches.jwt_decode?(call) } : claims
        reads.each do |read|
          key = read.name == :[] ? key_of(read.arguments&.arguments&.first, frame, locals) : nil
          add_cache(read, frame, holder, shape: "token claims", key: key)
        end
      end

      # The cache found at a node, once per place and shape.
      def add_cache(node, frame, holder, shape:, key:, expires_in: nil, versions: [])
        location = "#{frame.file}:#{node.location.start_line}"
        found = @caches.find { |cache| cache.location == location && cache.shape == shape }
        return found if found

        cache = Cache.new(shape: shape, key: key, expires_in: expires_in, holder: holder, location: location,
                          start: frame.start.label, path: frame.path, owner: frame.klass, versions: versions,
                          cleared: nil, accepted: nil, searched: [])
        @caches << cache
        cache
      end

      # `Rails.cache.fetch(key, expires_in: ...)` and the other reads,
      # through `Rails.cache` itself, a local assigned it or a constant.
      def rails_cache(call, frame, holder, locals)
        return nil unless Caches::READS.include?(call.name) && rails_cache?(call.receiver, frame, locals)

        args = call.arguments&.arguments || []
        versions = []
        key = key_of(args.first, frame, locals, versions)
        add_cache(call, frame, holder, shape: "Rails.cache.#{call.name}", key: key, versions: versions,
                                       expires_in: Caches.options(args)["expires_in"]&.slice)
      end

      def rails_cache?(node, frame, locals)
        case node
        when Prism::CallNode then Caches.rails_cache_call?(node)
        when Prism::LocalVariableReadNode then Caches.rails_cache_call?(locals[node.name.to_s])
        when Prism::ConstantReadNode
          owner = frame.klass
          scope = owner ? index_for(owner)&.scopes&.[](owner) : nil
          Caches.rails_cache_call?(scope&.constants&.[](node.name.to_s))
        else false
        end
      end

      # `session[...]`, `cookies[...]`, `cookies.signed[...]` and
      # `cookies.encrypted[...]` reads.
      def store_cache(call, frame, holder, locals)
        return nil unless call.name == :[] && (shape = store_shape(call.receiver))

        key = key_of(call.arguments&.arguments&.first, frame, locals)
        add_cache(call, frame, holder, shape: "#{shape}[...]", key: key)
      end

      def store_shape(node)
        return nil unless node.is_a?(Prism::CallNode) && node.arguments.nil?

        receiver = node.receiver
        return node.name.to_s if Caches::STORES.include?(node.name) && (receiver.nil? || named?(receiver, :request))

        Caches::JARS.include?(node.name) && named?(receiver, :cookies) ? "cookies.#{node.name}" : nil
      end

      def named?(node, name) = node.is_a?(Prism::CallNode) ? node.name == name : false

      # An index read whose key names a role, on a decoded token or a
      # receiver named `claims`, `payload` or `decoded_token`.
      def claim_read?(call, locals)
        return false unless call.name == :[]

        key = call.arguments&.arguments&.first
        return false unless key && key.slice.downcase.include?("role")

        claims?(call.receiver, locals)
      end

      def claims?(node, locals)
        case node
        when Prism::LocalVariableReadNode
          name = node.name.to_s
          Caches::CLAIMS.include?(name) || (locals[name].is_a?(Prism::Node) && claims?(locals[name], locals))
        when Prism::InstanceVariableReadNode then Caches::CLAIMS.include?(node.name.to_s.delete_prefix("@"))
        when Prism::CallNode
          return true if Caches.jwt_decode?(node)
          return Caches::CLAIMS.include?(node.name.to_s) if node.receiver.nil?

          %i[first [] dig].include?(node.name) && claims?(node.receiver, locals)
        else false
        end
      end

      # `@x ||= ...`, `@x[key] ||= ...`, `@@x ||= ...` and `CONST[key] ||= ...`
      # in a class method, when what it memoizes reads a parameter or the
      # user (a memo of literals, such as Mastodon's `UserRole.nobody`, is
      # the same for everyone).
      def memo_cache(node, frame, holder, method)
        variable = memo_variable(node)
        return unless variable && reads_input?(node, method)

        add_cache(node, frame, holder, shape: "class-level memo #{variable} ||=", key: variable)
      end

      def memo_variable(node)
        case node
        when Prism::InstanceVariableOrWriteNode, Prism::ClassVariableOrWriteNode then node.name.to_s
        when Prism::IndexOrWriteNode
          receiver = node.receiver
          case receiver
          when Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode, Prism::ConstantReadNode
            receiver.name.to_s
          end
        end
      end

      def reads_input?(node, method)
        params = all_parameters(method.node)
        all_nodes(node).any? do |child|
          case child
          when Prism::LocalVariableReadNode then params.include?(child.name.to_s)
          when Prism::InstanceVariableReadNode then child.name == :@user
          when Prism::CallNode then child.receiver.nil? && %i[user current_user].include?(child.name)
          else false
          end
        end
      end

      def all_parameters(node)
        params = node.parameters
        return [] unless params.is_a?(Prism::ParametersNode)

        [*params.requireds, *params.optionals, *params.keywords].filter_map do |param|
          param.is_a?(Prism::MultiTargetNode) ? nil : param.name.to_s
        end
      end

      # A key as a template; the classes whose version a key interpolates
      # are added to `versions`.
      def key_of(node, frame, locals, versions = [])
        case node
        when nil then nil
        when Prism::StringNode, Prism::SymbolNode then node.unescaped
        when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode then interpolated(node, frame, versions)
        when Prism::ArrayNode then node.elements.map { |element| key_of(element, frame, locals, versions) }.join("/")
        when Prism::LocalVariableReadNode
          value = locals[node.name.to_s]
          value.is_a?(Prism::Node) ? key_of(value, frame, locals, versions) : "{}"
        when Prism::CallNode then call_key(node, frame, versions)
        else "{}"
        end
      end

      def interpolated(node, frame, versions)
        node.parts.map do |part|
          next part.unescaped if part.is_a?(Prism::StringNode)

          each_node(part) { |child| versioned(child, frame, versions) }
          "{}"
        end.join
      end

      # `user.updated_at`, `cache_key_with_version` and the like name the
      # object whose touch refreshes the key.
      def versioned(node, frame, versions)
        return unless node.is_a?(Prism::CallNode) && Caches::VERSIONS.include?(node.name.to_s)

        receiver = node.receiver
        klass = receiver.nil? || receiver.is_a?(Prism::SelfNode) ? frame.klass : class_of(receiver, frame)
        versions << klass if klass && !versions.include?(klass)
      end

      # A key built by a method: `Class#name()`, matched against a deletion
      # calling the same method on a receiver of the same class.
      def call_key(node, frame, versions)
        if Caches::VERSIONS.include?(node.name.to_s)
          versioned(node, frame, versions)
          return "{}"
        end
        receiver = node.receiver
        klass = receiver.nil? || receiver.is_a?(Prism::SelfNode) ? frame.klass : class_of(receiver, frame)
        klass ? "#{klass}##{node.name}()" : "{}"
      end
    end
  end
end
