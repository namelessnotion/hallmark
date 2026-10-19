# frozen_string_literal: true

# A GitLab-shaped project host's DeclarativePolicy policies, written for the
# extractor tests (no app code is copied). Never loaded: Hallmark only
# parses them.
class BasePolicy < DeclarativePolicy::Base
  with_options scope: :user, score: 0
  condition(:admin) { @user&.admin? }
end
