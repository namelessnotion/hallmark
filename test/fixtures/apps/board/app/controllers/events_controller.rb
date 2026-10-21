# frozen_string_literal: true

# `set_event` loads the event through a helper the controller reader cannot
# type, so the policy comes from the variable's name (`@event`).
class EventsController < ApplicationController
  before_action :set_event

  def show
    authorize @event
  end

  def update
    authorize @event
    @event.update!(params[:event])
  end

  def ledger
    authorize @event
  end

  # Reached by a GET here and by a POST in `email_statement`.
  def statement
    authorize @event
  end

  def email_statement
    authorize @event, :statement?
  end

  def toggle_pinned
    authorize @event
  end

  def archive
    authorize @event
  end

  def new_payout
    authorize @event
  end

  # No route reaches it.
  def unrouted
    authorize @event, :unrouted?
  end

  private

  def set_event
    @event = lookup(params[:event_id] || params[:id])
  end
end
