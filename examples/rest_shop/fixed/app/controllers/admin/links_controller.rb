# frozen_string_literal: true

module Admin
  # The staff page: any seller's product.
  class LinksController < ApplicationController
    def show
      @link = Link.find(params[:id])
      authorize [:admin, @link]
      render json: @link, serializer: Admin::LinkSerializer
    end
  end
end
