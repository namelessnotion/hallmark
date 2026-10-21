# frozen_string_literal: true

module EE
  module Types
    module BoardType
      extend ActiveSupport::Concern

      prepended do
        field :insights, [::Types::CardType], null: true, camelize: false
      end
    end
  end
end
