# frozen_string_literal: true

# A CI host's DeclarativePolicy policies, written for the extractor tests
# (no app code is copied). Never loaded.
class BasePolicy < DeclarativePolicy::Base
  with_options scope: :user, score: 0
  condition(:admin) { @user&.admin? }
end
