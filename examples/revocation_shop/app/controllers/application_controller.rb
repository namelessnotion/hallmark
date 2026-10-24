# frozen_string_literal: true

# Who is signed in and which seller they act for come from headers, to
# keep the example small.
class ApplicationController < ActionController::API
  include Pundit::Authorization

  Context = Struct.new(:user, :seller)

  rescue_from(Pundit::NotAuthorizedError) { head :forbidden }

  private

  def pundit_user = Context.new(User.find(request.headers["X-User"]), User.find(request.headers["X-Seller"]))
end
