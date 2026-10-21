# frozen_string_literal: true

module Mutations
  # Checks in resolve, through a helper.
  class RenameBoard < BaseMutation
    argument :board_id, ID

    def resolve(board_id:)
      board = find_board(board_id)
      board.update!(name: "renamed")
    end

    private

    def find_board(id)
      authorized_find!(id: id)
    end
  end
end
