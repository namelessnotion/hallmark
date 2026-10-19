# frozen_string_literal: true

class LinksController < ApplicationController
  PUBLIC_ACTIONS = %i[show].freeze

  after_action :verify_authorized, except: PUBLIC_ACTIONS
  before_action :set_link, only: %i[edit update]

  def show; end

  def index
    authorize Link
  end

  def edit
    authorize @link
  end

  def update
    authorize @link
    @link.update!(params[:link])
  end

  def destroy
    link = current_seller.links.find(params[:id])
    authorize link
    link.destroy!
  end

  def archive
    authorize scoped_link
  end

  def publish
    link = Link.find_by(id: params[:id]) || e404
    authorize [:seller, link]
  end

  def preview
    authorize links.first
  end

  def duplicate
    authorize Link.where(user: current_seller).find(params[:id])
  end

  def variants
    authorize Link.find_by(user_id: current_seller.id), :index?
  end

  def copy
    authorize Link.find_by(owner: current_seller)
  end

  private

  def set_link
    @link = Link.find(params[:id])
  end

  def scoped_link
    @scoped_link ||= current_seller.links.find(params[:id])
  end
end
