# frozen_string_literal: true

module Admin
  # The staff page's product, without its buyers.
  class LinkSerializer < ActiveModel::Serializer
    attributes :id, :name, :price
  end
end
