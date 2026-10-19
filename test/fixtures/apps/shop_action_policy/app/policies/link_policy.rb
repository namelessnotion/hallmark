# frozen_string_literal: true

class LinkPolicy < ApplicationPolicy
  alias_rule :show?, to: :index?
  pre_check :allow_staff, except: %i[index?]

  def index?
    seller_team? || user.role_marketing_for?(seller)
  end

  def update?
    allow! if user.collaborator_for?(record)
    deny! if record.user != seller

    seller_team?
  end

  def edit?
    allowed_to?(:update?)
  end

  private

  def allow_staff
    allow! if user.staff?
  end

  def seller_team?
    user.role_owner_for?(seller) || user.role_admin_for?(seller)
  end
end
