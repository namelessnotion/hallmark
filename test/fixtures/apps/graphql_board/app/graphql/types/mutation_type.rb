# frozen_string_literal: true

module Types
  class MutationType < Types::BaseObject
    graphql_name "Mutation"

    field :move_card, mutation: Mutations::MoveCard
    field :archive_board, mutation: Mutations::ArchiveBoard, authorize: true
    field :rename_board, mutation: Mutations::RenameBoard
  end
end
