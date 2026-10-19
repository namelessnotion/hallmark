# frozen_string_literal: true

module CrudPolicyHelpers
  extend ActiveSupport::Concern

  class_methods do
    def read_update(name)
      [:"read_#{name}", *update_only(name)]
    end

    def update_only(name)
      [:"update_#{name}"]
    end
  end
end
