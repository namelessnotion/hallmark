# frozen_string_literal: true

module Mutations
  class ArchiveBoard < BaseMutation
    argument :board_id, ID, loads: Types::BoardType

    def authorized?(board:)
      super && context[:current_user].admin_of?(board)
    end

    def resolve(board:)
      board.archive!
    end
  end
end
