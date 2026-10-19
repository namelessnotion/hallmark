# typed: strict
# frozen_string_literal: true

module Hallmark
  # Which requests that finished without an authorization call (threat 10)
  # fail the report. One fails unless:
  #
  # - the mapping allows its entry point (`allow_unchecked`);
  # - its controller exempts the action from `verify_authorized` in code
  #   (`after_action :verify_authorized, except: PUBLIC_ACTIONS`), read by
  #   the extractor; listed as `coverage.exempt`;
  # - it was a GET or HEAD the action answered with a redirect while some
  #   other request to the same entry point reached a rule: a branch such as
  #   `return redirect_to root_path unless feature_enabled?` before
  #   `authorize`; listed as `coverage.redirected`. Writes that redirect,
  #   304s and empty 2xx still fail, and so does an entry point that never
  #   reached a rule (a signed-URL redirect may be an IDOR).
  #
  # An entry point fails when any of its unchecked requests is not excused.
  class UncheckedRequests
    # A redirect the browser follows with a GET: the response served no data.
    REDIRECTS = [301, 302, 303, 307, 308].freeze
    SAFE_VERBS = %w[GET HEAD].freeze

    def initialize(mapping, stamps, extractor, coverage)
      @mapping = mapping
      @stamps = stamps
      @extractor = extractor
      @coverage = coverage
    end

    # The failing entry points, sorted.
    def failing(events)
      events = events.reject { |event| @mapping.unchecked_allowed.include?(event.entry_point) }
      exempt, events = events.partition { |event| verify_skipped?(event.entry_point) }
      @coverage.exempt.concat(exempt.map(&:entry_point).uniq.sort)
      excused, failing = events.partition { |event| redirect_before_check?(event) }
      failed = failing.map(&:entry_point).uniq.sort
      @coverage.redirected.concat((excused.map(&:entry_point).uniq - failed).sort)
      failed
    end

    private

    def verify_skipped?(entry_point)
      read = @extractor&.controllers&.fetch(entry_point)
      read ? read.verify == :skipped : false
    end

    def redirect_before_check?(event)
      SAFE_VERBS.include?(event.verb) && REDIRECTS.include?(event.status) &&
        @stamps.any? { |stamp| stamp.entry_point == event.entry_point }
    end
  end
end
