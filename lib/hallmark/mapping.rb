# frozen_string_literal: true

module Hallmark
  # The one thing a developer must write: how application types correspond
  # to the catalog's types. Everything Hallmark cannot infer from this is a
  # modeling choice made explicit here rather than a silent assumption.
  class Mapping
    KINDS = %i[object profile].freeze

    Resource = Struct.new(:name, :owner, :kind, :public_if, keyword_init: true) do
      def sig = Naming.resource_sig(name, kind)
      def owned? = kind == :profile || !owner.nil?
      def public? = !public_if.nil? && public_if != false
      def always_public? = public_if == true
    end

    Grant = Struct.new(:role, :op, :resource, keyword_init: true) do
      def sig = "Grant_#{Naming.identifier(role)}_#{op}_#{Naming.identifier(resource)}"
    end

    OPS = %i[read write].freeze

    attr_reader :principal_name, :resources, :grants

    def initialize
      @principal_name = "User"
      @resources = {}
      @grants = []
    end

    # An intended permission: every holder of `role` may `op` every record of
    # `resource` (the catalog's explicit-permission pattern).
    #
    #   grant :moderator, :write, "Post"
    def grant(role, op, resource)
      raise ConfigurationError, "grant op must be :read or :write, not #{op.inspect}" unless OPS.include?(op)

      @grants << Grant.new(role: role.to_s, op: op, resource: resource.to_s)
    end

    # The application class that represents signed-in users (default "User").
    def principal(name)
      @principal_name = name.to_s
    end

    # owner:     association naming the owning user (e.g. :author), or nil when
    #            the record has no owner
    # kind:      :profile when each record describes one user (the user's own
    #            profile or account)
    # public_if: predicate under which a record is public (e.g. :published?),
    #            true when every record is public, nil when none is
    def resource(name, owner: nil, kind: :object, public_if: nil)
      raise ConfigurationError, "unknown resource kind: #{kind}" unless KINDS.include?(kind)

      key = name.to_s
      raise ConfigurationError, "resource #{key} is mapped twice" if @resources.key?(key)

      @resources[key] = Resource.new(name: key, owner: owner, kind: kind, public_if: public_if)
    end

    def fetch(name)
      @resources.fetch(name.to_s) do
        raise ConfigurationError, "resource #{name} is not mapped; add `resource \"#{name}\"` to the map block"
      end
    end

    def by_sig(sig)
      @resources.values.find { |resource| resource.sig == sig }
    end
  end
end
