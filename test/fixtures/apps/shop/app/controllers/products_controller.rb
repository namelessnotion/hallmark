# frozen_string_literal: true

# Actions that check the record in their own code as well as in the policy,
# whose show? rule asks only for a role in the current seller.
class ProductsController < ApplicationController
  after_action :verify_authorized
  before_action :fetch_link_and_enforce_access, only: %i[publish unpublish]
  before_action :require_staff, only: :feature

  def publish
    authorize @link, :show?
  end

  # A way out after the policy is the action's own logic, not read.
  def unpublish
    authorize @link, :show?
    return render(json: { error: "Already a draft" }) if @link.draft?

    @link.unpublish!
  end

  # Checked in the action itself, before the policy.
  def show
    link = Link.find(params[:id])
    return head(:not_found) if link.user != current_seller

    authorize link
  end

  def archive
    @link = Link.find(params[:id])
    link_accessible?(@link) || e404
    authorize @link, :show?
  end

  # A check on the record that Hallmark cannot read.
  def preview
    @link = Link.find(params[:id])
    redirect_to root_path and return unless @link.previewable?

    authorize @link, :show?
  end

  # Ways out that are not read: one on neither the record nor anything
  # read exactly, one inside a branch, and a render in the action, which
  # does not end it.
  def stats
    @link = Link.find(params[:id])
    return unless request.xhr?

    if params[:strict]
      e404 unless @link.user == current_seller
    end
    head :not_found unless @link.user == current_seller
    authorize @link, :show?
  end

  # A check on the user alone, read exactly.
  def feature
    authorize Link.find(params[:id]), :show?
  end

  # The callback's check sits in a branch on a parameter defaulting to true.
  before_action :fetch_link, only: :resend

  def resend
    authorize @link, :show?
  end

  private

  def fetch_link(owned = true)
    @link = Link.find(params[:id])
    if owned
      e404 if @link.user != current_seller
    end
  end

  def require_staff
    head :forbidden unless current_user&.staff?
  end
end
