# frozen_string_literal: true

module Types
  # Fixed: only the organization's admins see its invoices, however they
  # got here.
  class InvoiceType < Types::BaseObject
    def self.authorized?(object, context)
      super && context[:current_user]&.admin_of?(object.organization)
    end

    field :amount_cents, Integer, null: false
    field :paid, Boolean, null: false
  end
end
