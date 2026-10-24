# frozen_string_literal: true

# The REST shop's controllers. Hallmark reads them; nothing here is loaded.
class ApplicationController < ActionController::API
  include Pundit::Authorization

  after_action :verify_authorized

  private

  # The seller the request acts for, chosen in the session.
  def current_seller
    @current_seller ||= current_user.sellers.find(session[:seller_id])
  end
end
