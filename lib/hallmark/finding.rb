# frozen_string_literal: true

module Hallmark
  # A counterexample translated back into application terms: who can do what
  # to which record, and which catalog pattern the developer most likely
  # meant to implement.
  class Finding
    attr_reader :exposure, :principal, :record, :owner, :roles

    def self.from(exposure, instance, mapping)
      principal = instance.skolem("$#{exposure.check_name}_p")
      record = instance.skolem("$#{exposure.check_name}_r")
      raise SolverError, "counterexample for #{exposure.action} has no witness" unless principal && record

      new(
        exposure: exposure,
        mapping: mapping,
        principal: principal,
        record: record,
        owner: instance.field(record, "owner").first,
        roles: instance.field(principal, "assigned")
      )
    end

    def initialize(exposure:, mapping:, principal:, record:, owner:, roles:)
      @exposure = exposure
      @mapping = mapping
      @resource = mapping.fetch(exposure.resource)
      @principal = principal
      @record = record
      @owner = owner
      @roles = roles.map { |role| Naming.atom(role).sub(/\$\d+\z/, "").delete_prefix("Role_") }
    end

    def anonymous? = Naming.atom(principal).start_with?("Anonymous")
    def own_record? = !owner.nil? && owner == principal

    # The pattern the guard was most likely meant to implement, following the
    # SPACE classification of bugs by violated pattern.
    def pattern
      return "Authentication" if anonymous?
      return "Explicit permission" if exposure.guard.roles.any?
      return "User profiles" if @resource.kind == :profile
      return "Ownership" if @resource.owned?

      "Explicit permission"
    end

    def message
      "#{who} can #{verb} #{what}"
    end

    # A next step when the fix may be in the mapping rather than the code.
    def hint
      roles = exposure.guard.roles
      return nil if roles.empty? || anonymous?

      declarations = roles.map { |role| "grant :#{role}, :#{exposure.op}, \"#{exposure.resource}\"" }
      "if this is intended, declare it in the map block: #{declarations.join(" / ")}"
    end

    private

    def who
      return "an anonymous visitor" if anonymous?

      held = roles.empty? ? "no roles" : "roles #{roles.join(", ")}"
      "a signed-in #{@mapping.principal_name} (#{user_label(principal)}) holding #{held}"
    end

    def verb = exposure.op == :read ? "read" : "update"

    def what
      if @resource.kind == :profile
        own_record? ? "their own profile" : "the #{@resource.name} profile of #{user_label(owner)}"
      elsif @resource.owned?
        own_record? ? "a #{@resource.name} they own" : "a #{@resource.name} owned by #{user_label(owner)}"
      else
        "a #{@resource.name} (#{Naming.atom(record)})"
      end
    end

    def user_label(atom)
      "#{@mapping.principal_name}#{Naming.atom(atom).delete_prefix("User")}"
    end
  end
end
