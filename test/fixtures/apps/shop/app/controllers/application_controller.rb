# frozen_string_literal: true

# The shop's controllers, written for the extractor tests (no app code is
# copied). Never loaded: Hallmark only parses them.
class ApplicationController < ActionController::Base
  include Pundit::Authorization

  private

  def current_seller
    @current_seller ||= User.find(session[:seller_id])
  end

  def e404
    raise ActionController::RoutingError, "Not Found"
  end
end
