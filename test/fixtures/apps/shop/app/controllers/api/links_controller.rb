# frozen_string_literal: true

module Api
  # The shop's JSON API, written for the serializer reader's tests. Never
  # loaded.
  class LinksController < ApplicationController
    before_action :set_link, only: %i[show preview owner unknown export staff]
    after_action :verify_authorized

    def show
      authorize @link
      render json: @link, serializer: LinkSerializer
    end

    def preview
      authorize @link
      if @link.user == current_seller
        render json: @link, serializer: LinkSerializer, preview: true
      else
        render json: @link
      end
    end

    def index
      authorize Link
      render json: policy_scope(Link), each_serializer: LinkSerializer
    end

    def owner
      authorize @link, :show?
      render json: @link.user, serializer: UserSerializer
    end

    def unknown
      authorize @link, :show?
      render json: @link, serializer: serializer_for(@link)
    end

    def export
      authorize @link, :show?
      json = render_to_body json: @link, serializer: LinkSerializer, source_requested: true
      render json: json
    end

    def staff
      authorize [:admin, @link], :update?
      render_staff
    end

    private

    def set_link
      @link = Link.find(params[:id])
    end

    def render_staff
      render json: @link, serializer: Admin::LinkSerializer
    end
  end
end
