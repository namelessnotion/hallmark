# frozen_string_literal: true

class BoardPolicy < DeclarativePolicy::Base
  condition(:member) { @user&.member_of?(@subject) }
  condition(:admin) { @user&.admin_of?(@subject) }

  rule { member | admin }.enable :read_board
  rule { admin }.enable :admin_board
end
