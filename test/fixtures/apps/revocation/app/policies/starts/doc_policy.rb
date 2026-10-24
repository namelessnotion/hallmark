# frozen_string_literal: true

module Starts
  class DocPolicy
    attr_reader :user, :record

    def initialize(user, record)
      @user = user
      @record = record
    end

    def update? = admin?

    private

    def admin? = user.policy_role == "admin"
  end
end
