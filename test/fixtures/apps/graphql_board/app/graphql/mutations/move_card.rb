# frozen_string_literal: true

module Mutations
  # No check of its own, and load_card skips CardType's.
  class MoveCard < BaseMutation
    argument :card_id, ID, loads: Types::CardType

    def load_card(id)
      Card.find(id)
    end

    def resolve(card:)
      card.update!(moved: true)
    end
  end
end
