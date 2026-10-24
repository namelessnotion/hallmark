# frozen_string_literal: true

module Shapes
  class Membership < ApplicationRecord
    belongs_to :user, class_name: "Shapes::User"
    belongs_to :seller, class_name: "Shapes::User"
  end
end
