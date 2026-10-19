# typed: strict
# frozen_string_literal: true

module Hallmark
  # The Alloy for record flags (`resource ..., flags:`, guard `flag(:x)`): one
  # field of a single `RecordFlags` atom per flag, so witnesses carry flags
  # as tuples like any other field. A flag holds only for records of the
  # resources that declare it, and `public_when:` defines when such a record
  # is public.
  class FlagModel
    def initialize(resources)
      @resources = resources.select { |resource| resource.flags.any? }
    end

    # Nil when no resource declares a flag.
    def source
      names = @resources.flat_map(&:flags).uniq.sort
      return nil if names.empty?

      fields = names.map { |name| "#{Naming.flag_field(name)}: set Resource" }.join(", ")
      lines = ["-- Record flags", "one sig RecordFlags { #{fields} }"]
      names.each { |name| lines << holders(name) }
      lines.concat(@resources.filter_map { |resource| public_when(resource) })
      lines.join("\n")
    end

    private

    def holders(name)
      sigs = @resources.select { |resource| resource.flags.include?(name) }.map(&:alloy_sig).join(" + ")
      "fact #{Naming.flag_field(name)}_holders { #{Naming.flag_sig(name)} in #{sigs} }"
    end

    def public_when(resource)
      guard = resource.public_when
      return nil unless guard

      sig = resource.alloy_sig
      "fact #{sig}_public_when { all r: #{sig} | r in Public iff #{guard.to_alloy} }"
    end
  end
end
