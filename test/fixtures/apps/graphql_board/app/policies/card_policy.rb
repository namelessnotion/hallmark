# frozen_string_literal: true

class CardPolicy < ActionPolicy::Base
  def show?
    user.member_of?(record.board)
  end
end
