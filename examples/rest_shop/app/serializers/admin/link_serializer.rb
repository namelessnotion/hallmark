# frozen_string_literal: true

module Admin
  # The staff page's product, with who bought it.
  class LinkSerializer < ActiveModel::Serializer
    attributes :id, :name, :price, :buyer_emails
  end
end
