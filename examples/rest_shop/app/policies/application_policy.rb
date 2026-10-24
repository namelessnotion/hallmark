# frozen_string_literal: true

# The REST shop's policies (Pundit), as README.md describes them. Hallmark
# reads this code; nothing here is loaded.
class ApplicationPolicy
  attr_reader :user, :seller, :record

  # `context` carries the signed-in user and the seller the request acts for.
  def initialize(context, record)
    @user = context.user
    @seller = context.seller
    @record = record
    raise Pundit::NotAuthorizedError, "must be logged in" unless user
  end
end
