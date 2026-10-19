# frozen_string_literal: true

class LinkPolicy < ApplicationPolicy
  def index?
    seller_team? || user.role_marketing_for?(seller)
  end

  def edit?
    return true if user.staff?

    update?
  end

  def update?
    return true if user.collaborator_for?(record)
    return false if @record.user != seller

    seller_team?
  end

  def show?
    index?
  end

  def destroy?
    when_record { record.user == seller } && seller_team?
  end

  def publish?
    owner = record.user
    owner == seller ? seller_team? : false
  end

  def archive?
    unless record.user == seller
      return false
    end

    user.role_owner_for?(seller)
  end

  def preview?
    user.feature_enabled?(:previews) && index?
  end

  def loop?
    loop?
  end

  def helper_with_args?(other) = other

  private

  def seller_team?
    user.role_owner_for?(seller) || user.role_admin_for?(seller)
  end
end
