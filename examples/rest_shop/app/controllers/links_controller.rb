# frozen_string_literal: true

# The seller's team reads its products through the API.
class LinksController < ApplicationController
  def show
    @link = current_seller.links.find(params[:id])
    authorize @link
    render json: @link, serializer: LinkSerializer
  end
end
