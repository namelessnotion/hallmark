# typed: strict
# frozen_string_literal: true

module Hallmark
  # Inference's entry points no test reached: Rails routes the Railtie
  # recorded, and Grape endpoints read from code (phase 2 steps 3 and 4).
  class Inference
    private

    # Routes no test reached (no stamp, no unchecked request), read from
    # their controller: an exposure for each rule it authorizes that the
    # extractor read, with the rule's code guard alone. What cannot be read
    # is listed under coverage, never failed: the code may authorize in ways
    # Hallmark does not read.
    def route_exposures
      return [] unless (controllers = self.controllers)

      rails = (@routes.map(&:entry_point).uniq - @reached).sort.flat_map do |entry_point|
        read = controllers.fetch(entry_point)
        next [] if read&.verify == :skipped
        next route_exposures_of(entry_point, read.authorizations, read.checked) if read

        @coverage.routes_unread << entry_point
        []
      end
      rails + grape_exposures
    end

    # Grape endpoints (GitLab's REST API) no test reached, read from code;
    # every endpoint is known statically, so no routes are needed.
    def grape_exposures
      endpoints = @extractor&.grape&.endpoints || []
      endpoints.reject { |endpoint| @reached.include?(endpoint.name) }.sort_by(&:name).flat_map do |endpoint|
        route_exposures_of(endpoint.name, endpoint.authorizations, endpoint.checked?)
      end
    end

    def route_exposures_of(entry_point, authorizations, checked)
      unless checked
        @coverage.routes_unchecked << entry_point
        return []
      end

      units = authorizations.filter_map { |authorization| route_unit(authorization) }
      @coverage.routes_unresolved << entry_point if units.size < authorizations.size
      units.each { |unit| @coverage.code_only.delete(unit.key) }
      exposures_of(entry_point, units).each do |exposure|
        exposure.basis = "no test reached this route, read from code: #{exposure.basis}"
      end
    end

    # The unit for an authorize call's rule, reusing the one for its stamps
    # or code when there is one.
    def route_unit(authorization)
      policy = authorization.policy
      return nil unless policy

      key = "#{policy}##{authorization.rule}"
      @units.find do |unit|
        unit.key == key && unit.extracted
      end || code_unit(@extractor&.fetch(policy, authorization.rule))
    end

    def code_unit(extracted)
      resource = extracted&.resource
      return nil unless extracted && resource && (op = @mapping.op_for(extracted.policy, extracted.rule))

      unit = Unit.new(policy: extracted.policy, rule: extracted.rule, resource: resource, op: op, stamps: [],
                      extracted: extracted)
      assign_guard(unit)
      unit
    end
  end
end
