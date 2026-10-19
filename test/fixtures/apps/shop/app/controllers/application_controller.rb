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

  # A check made outside the policy, shared by several controllers.
  def fetch_link_and_enforce_access
    @link = Link.find_by(permalink: params[:id])
    e404 unless link_accessible?(@link)
  end

  def link_accessible?(link)
    link.present? && (link.user == current_seller || current_user&.collaborator_for?(link))
  end
end
