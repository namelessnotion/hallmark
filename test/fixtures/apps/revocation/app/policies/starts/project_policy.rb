# frozen_string_literal: true

module Starts
  class ProjectPolicy < DeclarativePolicy::Base
    condition(:admin) { @user.dp_role == "admin" }

    rule { admin }.enable :edit_project
  end
end
