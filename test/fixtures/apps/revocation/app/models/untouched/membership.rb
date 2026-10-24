# frozen_string_literal: true

module Untouched
  class Membership < ApplicationRecord
    belongs_to :user, class_name: "Untouched::User"
  end
end
