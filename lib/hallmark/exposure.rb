# typed: strict
# frozen_string_literal: true

module Hallmark
  # One way the application lets a request read or write a kind of record,
  # and the guard it applies first. SPACE derived these by symbolic execution;
  # Hallmark derives them from policy code and runtime events.
  #
  # `basis` says where an inferred exposure's guard came from, such as
  # "inferred from 3 allow-stamps of LinkPolicy#update?"; nil when the
  # analysis declares the exposure by hand.
  #
  # An exposure is the entry point, the op and the resource together
  # (docs/adr/0001), so the generated names carry all three: one entry point
  # may read two kinds of record.
  #
  # `locations` are the source lines behind an exposure read from code
  # ("app/controllers/links_controller.rb:42"): the entry point's authorize
  # call or Grape endpoint first, then the rules' code and the controller's
  # own checks. Empty for a hand-declared exposure. SARIF output uses them.
  #
  # `rules` are the rules ("LinkPolicy#update?") whose guards the exposure's
  # guard combines; nil for a hand-declared exposure. The model reads them
  # for the public actions pattern (`Mapping#public_action_for`).
  Exposure = Struct.new(:action, :op, :resource, :guard, :basis, :locations, :rules, keyword_init: true) do
    def check_name = "safe_#{name_suffix}"
    def predicate_name = "allows_#{name_suffix}"
    def name_suffix = "#{Naming.identifier(action)}_#{op}_#{Naming.identifier(resource)}"

    def to_s = "#{action} (#{op} #{resource}, guard: #{guard})"
  end
end
