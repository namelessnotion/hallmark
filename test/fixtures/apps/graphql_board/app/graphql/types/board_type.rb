# frozen_string_literal: true

module Types
  class BoardType < Types::BaseObject
    authorize :read_board
    implements Types::SearchableInterface

    field :cards, Types::CardType.connection_type, null: false
    field :lanes, [Types::LaneType], null: false
    field :notes, [Types::NoteType], null: false, scope: false
    field :owner_name, String, null: false, authorize: :admin_board
    field :pinned, Types::CardType, null: true, authorize: true
    field :secret, String, null: true do
      def authorized?(obj, args, ctx)
        super && ctx[:current_user].present?
      end
    end
  end
end

Types::BoardType.prepend_mod_with("Types::BoardType")
