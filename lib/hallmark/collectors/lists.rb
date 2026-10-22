# typed: strict
# frozen_string_literal: true

module Hallmark
  # The collectors' list scopes (see collectors.rb for the rest).
  module Collectors
    # List scopes (phase 3 step 7): Pundit's `Scope#resolve`, Action
    # Policy's scopes and graphql-ruby's `scope_items` each mark the request
    # as checked, and when it is sampled also stamp a list decision: the
    # call, class-level (the scope's rule and the records' class), and the
    # facts of at most `ListScope::RECORDS_READ` records of its result,
    # each an allow-stamp with `list` set. Only records the app loads are
    # read: an Array, or a relation already loaded, at once; a relation
    # not loaded yet, when the app loads it later in the same request
    # (`ListProbe`, put on that one result). Records the app never loads
    # (it only counts them, say) leave the call stamp alone.
    module ListProbe
      # The list a result came from: the policy facts are read off, the
      # scope's rule and the request it was made in.
      Origin = Struct.new(:policy, :rule, :request)

      # Extended onto one lazy result: stamps its records once it loads.
      # A relation chained off it (`.includes(...)`) is a clone and keeps
      # the probe, which is right: its records are the list's too.
      module Loading
        def load(*, **, &)
          before = loaded?
          result = super
          ListProbe.loaded(self) unless before
          result
        end
      end

      ORIGIN = :@hallmark_list

      class << self
        # Stamps the result's records now if it holds them, else puts the
        # probe on it. Never raises.
        def attach(result, origin)
          records = loaded_records(result)
          return Collectors.list_records(origin, records) if records
          return unless result.respond_to?(:load) && result.respond_to?(:loaded?) && !result.frozen?

          result.instance_variable_set(ORIGIN, origin)
          result.extend(Loading)
        rescue StandardError => e
          Collectors.warn_once(e)
        end

        # A probed result has loaded: stamps its records if it is still
        # the same request (and outside one, if it was made outside one).
        def loaded(result)
          origin = result.instance_variable_get(ORIGIN)
          return unless origin.is_a?(Origin) && Collectors.active?
          return unless Collectors.current_request.equal?(origin.request)

          records = loaded_records(result)
          Collectors.list_records(origin, records) if records
        rescue StandardError => e
          Collectors.warn_once(e)
        end

        # What a result holds without a query: an Array, or a loaded
        # relation's records; nil otherwise.
        def loaded_records(result)
          return result if result.is_a?(Array)
          return nil unless result.respond_to?(:loaded?) && result.loaded?

          result.respond_to?(:records) ? result.records : nil
        end

        # The class of the records a scope lists: a class given as the
        # scope, a relation's `klass`, an Array's first element's class.
        def model_of(value)
          return value if value.is_a?(Class)
          return value.klass if value.respond_to?(:klass) && value.klass.is_a?(Class)
          return value.first&.class if value.is_a?(Array)

          nil
        end
      end
    end

    class << self
      # Marks the request checked and, when sampled, stamps the list call
      # and the records of `result` (`ListProbe`). `model` is the class of
      # what the scope started from, when the result does not say.
      def list(policy:, rule:, result:, model: nil)
        checked!
        klass = recording? ? ListProbe.model_of(result) || ListProbe.model_of(model) : nil
        facts = @facts
        store = @store
        return unless klass && facts && store

        store.record(facts.list_call(policy: policy, rule: rule, model: klass,
                                     entry_point: current_request&.entry_point_name))
        ListProbe.attach(result, ListProbe::Origin.new(policy, rule, current_request))
      rescue StandardError => e
        warn_once(e)
      end

      # One allow-stamp per record read, at most ListScope::RECORDS_READ.
      def list_records(origin, records)
        records.first(ListScope::RECORDS_READ).each do |record|
          decision(policy: origin.policy, rule: origin.rule, record: record, allowed: true, enforced: false,
                   list: true)
        end
      end
    end
  end
end
