# frozen_string_literal: true

# A product, in its seller's shop.
class Link < ApplicationRecord
  belongs_to :user
end
