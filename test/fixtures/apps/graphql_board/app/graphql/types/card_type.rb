# frozen_string_literal: true

module Types
  class CardType < Types::BaseObject
    graphql_name "Ticket"
    implements Types::SearchableInterface
    reauthorize_scoped_objects(false)

    def self.authorized?(object, context)
      context[:current_user]&.member_of?(object.board)
    end

    def self.scope_items(items, context)
      items.where(board: context[:current_board])
    end

    field :board, Types::BoardType, null: false
  end
end
