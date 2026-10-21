# typed: strict
# frozen_string_literal: true

module Hallmark
  # What must never happen even when a catalog pattern allows it (threat
  # 11), declared with `restrict` in the map block: a name and its denials.
  # Each restriction covering an exposure ANDs its negation into that
  # exposure's check (`ModelBuilder#intended`).
  #
  #   restrict "admins never read card numbers" do
  #     deny role: :admin, op: :read, resource: "PaymentMethod", fields: %i[number cvc]
  #   end
  Restriction = Struct.new(:name, :denials, keyword_init: true) do
    def self.build(name, &)
      builder = Restriction::Builder.new(name)
      builder.instance_eval(&)
      raise ConfigurationError, "restriction #{name.inspect} denies nothing; add a `deny`" if builder.denials.empty?

      new(name: name, denials: builder.denials)
    end

    def covering(exposure) = denials.select { |denial| denial.covers?(exposure) }
    def covers?(exposure) = denials.any? { |denial| denial.covers?(exposure) }
    def roles = denials.map(&:role).uniq

    # `not (d1 or d2)` over the denials covering `exposure`, for its check.
    def negation(exposure, platform_roles)
      "(not (#{covering(exposure).map { |denial| denial.to_alloy(platform_roles) }.join(" or ")}))"
    end

    # Its resources must be mapped, its roles declared (a misspelt role
    # would make a check that never fires), and a `when:` may read only
    # the resource's flags.
    def validate!(mapping)
      declared = mapping.declared_roles
      denials.each do |denial|
        resource = mapping.fetch(denial.resource)
        unless declared.include?(denial.role)
          raise ConfigurationError, "restriction #{name.inspect} denies role #{denial.role}, which the map block " \
                                    "never declares (a grant, a platform_role, `self:` or a field policy)"
        end
        stray = (denial.condition&.flags || []) - resource.flags
        next if stray.empty?

        raise ConfigurationError, "restriction #{name.inspect} reads flags #{resource.name} does not declare: " \
                                  "#{stray.join(", ")}; add them to its `flags:`"
      end
    end
  end

  class Restriction
    # One `deny`: holders of `role` must never perform `ops` on `resource`
    # (only on `fields` of it when set; every exposure of it, field or not,
    # when nil), on the records whose flags satisfy `condition` (every
    # record when nil).
    Denial = Struct.new(:role, :ops, :resource, :fields, :condition, keyword_init: true) do
      def covers?(exposure)
        names = fields
        resource == exposure.resource && ops.include?(exposure.op) &&
          (names.nil? || names.include?(exposure.field.to_s))
      end

      # The role counts in the record's tenant (`rolesFor`), or anywhere
      # for a platform role, which no membership holds.
      def to_alloy(platform_roles)
        roles = platform_roles.include?(role) ? "effective[p]" : "rolesFor[p, r]"
        held = "#{Naming.role_sig(role)} in #{roles}"
        (guard = condition) ? "(#{held} and #{guard.to_alloy})" : held
      end

      def to_s
        parts = ["role: :#{role}", "op: #{ops.size == 1 ? ":#{ops.first}" : "%i[#{ops.join(" ")}]"}",
                 "resource: \"#{resource}\""]
        if (names = fields)
          parts << "fields: %i[#{names.join(" ")}]"
        end
        parts << "when: #{condition}" if condition
        "deny #{parts.join(", ")}"
      end
    end

    # Evaluation context for a `restrict` block.
    class Builder
      include Guard::DSL

      attr_reader :denials

      def initialize(name)
        @name = name
        @denials = []
      end

      # role:   the role whose holders are denied
      # op:     :read, :write or both (%i[read write])
      # fields: the fields of `resource` this protects, for reads only; nil
      #         for the whole record and every field of it
      # when:   a guard over the resource's flags limiting the records
      def deny(role:, op:, resource:, fields: nil, when: nil)
        ops = ops(op)
        names = fields && Array(fields).map(&:to_s)
        if names && (names.empty? || ops != [:read])
          raise ConfigurationError, "restriction #{@name.inspect}: `fields:` needs `op: :read` and at least one " \
                                    "field (fields exist only on reads)"
        end

        condition = Mapping.flag_condition(binding.local_variable_get(:when), "a restriction's")
        @denials << Denial.new(role: role.to_s, ops: ops, resource: Naming.class_name(resource), fields: names,
                               condition: condition)
      end

      private

      def ops(op)
        ops = Array(op)
        return Mapping::OPS & ops if !ops.empty? && ops.all? { |each| Mapping::OPS.include?(each) }

        raise ConfigurationError, "restriction #{@name.inspect}: `op:` must be :read, :write or both, not #{op.inspect}"
      end
    end
  end
end
