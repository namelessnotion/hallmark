# typed: strict
# frozen_string_literal: true

module Hallmark
  # Turns application names into Alloy identifiers that cannot collide with
  # the catalog's own signatures, and back again.
  module Naming
    CATALOG_NAMES = %w[
      Op Read Write Principal Anonymous User Role Admin PlatformRole Tenant Membership
      Resource Public Grant Permit Conflict CanAssign
    ].freeze

    module_function

    def identifier(text)
      id = text.to_s.gsub(/[^A-Za-z0-9_]/, "_").gsub(/_+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
      id = "X#{id}" unless id.match?(/\A[A-Za-z]/)
      id
    end

    # A class constant or a class name, as the class name: User or "User" -> "User"
    def class_name(value)
      return value.to_s unless value.is_a?(Module)

      value.name || Kernel.raise(ConfigurationError, "cannot map an anonymous class: #{value.inspect}")
    end

    def resource_sig(name, kind)
      base = identifier(name)
      return "#{base}Profile" if kind == :profile
      return "#{base}Record" if CATALOG_NAMES.include?(base)

      base
    end

    def role_sig(name)
      "Role_#{identifier(name)}"
    end

    # A record flag is a field of the one `RecordFlags` atom, so witnesses
    # carry it as tuples like any other field.
    def flag_field(name)
      "flag_#{identifier(name)}"
    end

    def flag_sig(name)
      "RecordFlags.#{flag_field(name)}"
    end

    # "catalog/User$0" -> "User$0"
    def atom(name)
      name.to_s.split("/").last.to_s
    end
  end
end
