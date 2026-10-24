# frozen_string_literal: true

# Policies get the signed-in user and the seller the request acts for.
class ApplicationPolicy
  attr_reader :user, :seller, :record

  def initialize(context, record)
    @user = context.user
    @seller = context.seller
    @record = record
  end
end
