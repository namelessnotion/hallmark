# frozen_string_literal: true

module Hallmark
  # One way the application lets a request read or write a kind of record,
  # and the guard it applies first. SPACE derived these by symbolic execution;
  # Hallmark derives them from policy code and runtime events.
  Exposure = Struct.new(:action, :op, :resource, :guard, keyword_init: true) do
    def check_name
      "safe_#{Naming.identifier(action)}_#{op}"
    end

    def predicate_name
      "allows_#{Naming.identifier(action)}_#{op}"
    end

    def to_s = "#{action} (#{op} #{resource}, guard: #{guard})"
  end
end
