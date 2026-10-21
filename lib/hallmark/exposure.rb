# typed: strict
# frozen_string_literal: true

require "digest"
require "json"

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
  #
  # `field` is the one field a read exposure reads ("email"), checked
  # against the record's read and the field's policy
  # (`Mapping#field_policy`); nil for the whole record.
  Exposure = Struct.new(:action, :op, :resource, :guard, :basis, :locations, :rules, :field,
                        keyword_init: true) do
    def check_name = "safe_#{name_suffix}"
    def predicate_name = "allows_#{name_suffix}"

    def name_suffix
      suffix = "#{Naming.identifier(action)}_#{op}_#{Naming.identifier(resource)}"
      (name = field) ? "#{suffix}_#{Naming.identifier(name)}" : suffix
    end

    # What it reads or writes: "Link", or "User.email" for a field.
    def target = field ? "#{resource}.#{field}" : resource

    def to_s = "#{action} (#{op} #{target}, guard: #{guard})"

    # SHA-256 of what the model builder renders for this exposure and what
    # that depends on: its names, op, resource, field, guard, rules, the
    # public action the mapping gives those rules, the field's policy and
    # the restrictions covering it. Two equal digests make the same check,
    # so a baseline and `hallmark watch` agree on what changed.
    def digest(mapping)
      action = mapping.public_action_for(rules || [])
      public_action = action && "#{action.audience} #{action.condition}"
      parts = [check_name, op.to_s, resource, guard.to_s, (rules || []).sort, public_action]
      Digest::SHA256.hexdigest(JSON.generate(parts + narrowing(mapping)))
    end

    # The field, its policy and the covering restrictions, for `digest`;
    # empty when there are none, so a baseline written before fields
    # existed still matches.
    def narrowing(mapping)
      restrictions = mapping.restrictions_for(self).map do |restriction|
        [restriction.name, restriction.covering(self).map(&:to_s)]
      end
      return [] if field.nil? && restrictions.empty?

      [field, mapping.field_policy_for(resource, field)&.guard.to_s, restrictions]
    end
  end
end
