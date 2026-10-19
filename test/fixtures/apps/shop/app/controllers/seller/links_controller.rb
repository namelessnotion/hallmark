# frozen_string_literal: true

module Seller
  # The same actions, loading the link through the current seller.
  class LinksController < ::LinksController
    skip_before_action :set_link
    before_action :set_seller_link, only: %i[edit update]
    skip_after_action :verify_authorized, only: :update

    private

    def set_seller_link
      @link = current_seller.links.find(params[:id])
    end
  end
end
