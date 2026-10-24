# frozen_string_literal: true

# Updates a product, if the policy lets the user.
class LinksController < ApplicationController
  def update
    link = Link.find(params[:id])
    authorize link
    link.update!(name: params[:name])
    head :ok
  end
end
