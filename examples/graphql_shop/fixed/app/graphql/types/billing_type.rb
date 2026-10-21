# frozen_string_literal: true

module Types
  # A project's billing page; it wraps the project itself and backs no
  # record of its own.
  class BillingType < Types::BaseObject
    field :invoices, [Types::InvoiceType], null: false
  end
end
