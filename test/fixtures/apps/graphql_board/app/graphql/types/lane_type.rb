# frozen_string_literal: true

module Types
  # Backs no mapped resource and checks its own ability.
  class LaneType < Types::BaseObject
    authorize :read_lane

    field :cards, [Types::CardType], null: false
  end
end
