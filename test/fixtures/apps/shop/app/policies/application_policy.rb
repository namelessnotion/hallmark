# frozen_string_literal: true

# A Gumroad-shaped shop's Pundit policies, written for the extractor tests
# (no app code is copied). Never loaded: Hallmark only parses them.
class ApplicationPolicy
  attr_reader :user, :seller, :record

  class_attribute :allow_anonymous, default: false

  def self.allow_anonymous!
    self.allow_anonymous = true
  end

  def initialize(context, record)
    @user = context.user
    @seller = context.seller
    @record = record
    raise Pundit::NotAuthorizedError, "must be logged in" if !@user && !allow_anonymous
  end

  private

  def when_record(&block)
    record.is_a?(Class) || block.call
  end
end
