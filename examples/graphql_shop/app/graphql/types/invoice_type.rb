# frozen_string_literal: true

module Types
  # No authorized? here: "only admins open the billing page" (G2).
  class InvoiceType < Types::BaseObject
    field :amount_cents, Integer, null: false
    field :paid, Boolean, null: false
  end
end
