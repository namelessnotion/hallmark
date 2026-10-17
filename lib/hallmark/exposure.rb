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
  Exposure = Struct.new(:action, :op, :resource, :guard, :basis, keyword_init: true) do
    def check_name = "safe_#{name_suffix}"
    def predicate_name = "allows_#{name_suffix}"
    def name_suffix = "#{Naming.identifier(action)}_#{op}_#{Naming.identifier(resource)}"

    def to_s = "#{action} (#{op} #{resource}, guard: #{guard})"
  end
end
