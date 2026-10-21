# frozen_string_literal: true

class EventPolicy < ApplicationPolicy
  def show? = user.present?
  def update? = user.present?
  def ledger? = user.present?
  def statement? = user.present?
  def toggle_pinned? = user.present?
  def archive? = user.present?
  def new_payout? = user.present?
  def unrouted? = user.present?
end
