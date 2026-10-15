# frozen_string_literal: true

module Hallmark
  # Turns application names into Alloy identifiers that cannot collide with
  # the catalog's own signatures, and back again.
  module Naming
    CATALOG_NAMES = %w[
      Op Read Write Principal Anonymous User Role Admin Resource Public Grant
      Conflict CanAssign
    ].freeze

    module_function

    def identifier(text)
      id = text.to_s.gsub(/[^A-Za-z0-9_]/, "_").gsub(/_+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
      id = "X#{id}" unless id.match?(/\A[A-Za-z]/)
      id
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

    # "catalog/User$0" -> "User$0"
    def atom(name)
      name.to_s.split("/").last
    end
  end
end
