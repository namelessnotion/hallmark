# frozen_string_literal: true

module Admin
  # The staff page's product: buyers always. Never loaded.
  class LinkSerializer < ::LinkSerializer
    attribute :buyer_emails
  end
end
