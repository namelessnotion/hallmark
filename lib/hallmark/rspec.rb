# typed: strict
# frozen_string_literal: true

require_relative "../hallmark"

module Hallmark
  # RSpec matchers that check a policy's rules against the catalog, one rule
  # at a time (`Hallmark::RuleCheck`). Load them with `require "hallmark/rspec"`.
  #
  #   RSpec.describe LinkPolicy, :hallmark do
  #     it { is_expected.to satisfy_catalog }                 # every known rule
  #     it { is_expected.to have_no_counterexample(:update?) }
  #   end
  #
  # A matcher passes only on "no counterexample within scope N". It fails on
  # a counterexample (printed as `hallmark check` prints it), on an unknown
  # verdict, and on a rule with nothing to check (no allow-stamp and no
  # hand-written guard: not observed, which is a coverage gap and not a
  # finding, but not a pass either).
  #
  # Where the pieces come from:
  #
  #   mapping  `let(:hallmark_mapping)` in the example group, else the
  #            configured one (`Hallmark.configure { |c| c.map { ... } }`, which
  #            the Railtie loads from config/hallmark.rb), else
  #            config/hallmark.rb under the working directory
  #   guards   the mapping's `rule ..., guard:`, else read from policy code
  #            under `let(:hallmark_root)` or `c.root` (the Rails root under
  #            the Railtie; docs/adr/0003) OR inferred from stamps:
  #            `let(:hallmark_stamps)` (a StampSet or a path), else the run the
  #            collectors are recording in this process (flushed first), else
  #            the run written last in `c.stamps` (tmp/hallmark)
  #   solver   the sidecar, started on the first check and stopped after the
  #            suite, unless HALLMARK_SOLVER or `c.solver` picks a backend; the
  #            CLI when the sidecar is not built
  #
  # The `:hallmark` tag makes the described policy class (or name) the
  # subject, rather than an instance, which Pundit and Action Policy cannot
  # build without a user, and runs tagged groups after the others, so a
  # rule's guard is inferred from every stamp the rest of the suite recorded.
  module RSpec
    CONFIG_FILE = "config/hallmark.rb"

    class << self
      # Replaces the backend, for tests or a custom backend.
      attr_writer :solver

      # The backend every matcher in this process shares.
      def solver
        @solver ||= begin
          config = Hallmark.configuration
          if config.solver_chosen?
            Solver.build(config)
          else
            sidecar = Solver::Sidecar.new(config)
            sidecar.available? ? sidecar : Solver::CLI.new(config)
          end
        end
      end

      def close
        @solver&.close
        @solver = nil
      end

      def mapping
        config = Hallmark.configuration
        load File.expand_path(CONFIG_FILE) if config.mapping.nil? && File.file?(CONFIG_FILE)
        config.mapping || raise(ConfigurationError, "no mapping for the Hallmark matchers; declare one with " \
                                                    "`Hallmark.configure { |c| c.map { ... } }` in #{CONFIG_FILE}")
      end

      # The stamps guards are inferred from: the run being recorded in this
      # process when the collectors are on, else the run `c.run` names
      # (HALLMARK_RUN), else the run written last.
      # Empty when there are none (every rule is then not observed unless its
      # guard is hand-written).
      def stamps
        store = Collectors.store
        if Collectors.active? && store
          store.flush
          return StampSet.read(StampSet.files(store.dir, run: store.run))
        end

        config = Hallmark.configuration
        StampSet.read(StampSet.files(config.stamps, run: config.run))
      end

      def install(config)
        config.include Matchers
        config.include PolicySubject, :hallmark
        config.when_first_matching_example_defined(:hallmark) { RSpec.order_last(config) }
        config.after(:suite) { RSpec.close }
      end

      # Wraps the suite's ordering (random or defined, from the command line
      # or the configuration) so that groups tagged `:hallmark` run after
      # their siblings. RSpec marks its ordering registry private, and
      # `register_ordering` ignores a change once `--order` is given, so this
      # writes to the registry; without one the order is left alone.
      def order_last(config)
        return unless config.respond_to?(:ordering_registry)

        registry = config.ordering_registry
        registry.register(:global, LastOrdering.new(registry.fetch(:global)))
      end
    end

    # An RSpec ordering strategy: the suite's own order, then tagged groups
    # moved to the end of each list.
    class LastOrdering
      def initialize(previous)
        @previous = previous
      end

      def order(items)
        first, last = @previous.order(items).partition { |item| !item.metadata[:hallmark] }
        first + last
      end
    end

    # Shared by both matchers: runs the checks and words the outcome.
    class Matcher
      UNKNOWN_NOTE = "An unknown is not a pass: the solver gave no verdict. Raise HALLMARK_TIMEOUT or lower the scope."
      NOT_OBSERVED_NOTE = "Not observed means there was no guard to check: a coverage gap, not a finding. Exercise " \
                          "an allowed case in a spec that runs before this one (with the collectors on), or " \
                          "declare `rule POLICY, NAME, guard: ...` in the map block."

      attr_reader :results

      # `stamps` is a StampSet or a path to stamps (a JSONL file or a stamp
      # directory). Each option defaults as described on Hallmark::RSpec.
      def initialize(mapping: nil, stamps: nil, root: nil, solver: nil)
        @mapping = mapping
        @stamps = stamps
        @root = root
        @solver = solver
        @policy = ""
        @results = []
      end

      def matches?(actual)
        @results = run(actual)
        @results.any? && @results.all?(&:none?)
      end

      # `not_to` passes only on a counterexample; an unknown or a rule with
      # nothing to check fails it too.
      def does_not_match?(actual)
        @results = run(actual)
        @results.any?(&:counterexample?)
      end

      def failure_message
        "expected #{target} to #{expectation}; #{outcome}:\n\n#{details}"
      end

      def failure_message_when_negated
        "expected #{target} to have a counterexample within scope #{scope}; #{outcome}:\n\n#{details}"
      end

      private

      def scope = Hallmark.configuration.scope
      def target = @policy
      def expectation = "have no counterexample within scope #{scope}"
      def rule_names = nil

      def run(actual)
        @policy = policy_name(actual)
        mapping = @mapping || RSpec.mapping
        check = RuleCheck.new(mapping, stamp_set,
                              extractor: Extractor.load(mapping, @root || Hallmark.configuration.root))
        check.check(@policy, rule_names, solver: @solver || RSpec.solver)
      end

      # A policy class, an instance of one, or a class name.
      def policy_name(actual)
        case actual
        when Module then Naming.class_name(actual)
        when String, Symbol then actual.to_s
        else Naming.class_name(actual.class)
        end
      end

      def stamp_set
        stamps = @stamps
        case stamps
        when StampSet then stamps
        when nil then RSpec.stamps
        else StampSet.read(StampSet.files(stamps.to_s))
        end
      end

      def outcome
        return "no rules of #{@policy} were stamped or have a hand-written guard" if @results.empty?

        counts = %i[counterexample unknown not_observed none].filter_map do |verdict|
          number = @results.count { |result| result.verdict == verdict }
          "#{number} #{label(verdict, number)}" if number.positive?
        end
        "#{counts.join(", ")} in #{@results.size} rule#{"s" unless @results.size == 1}"
      end

      def label(verdict, number)
        case verdict
        when :counterexample then "counterexample#{"s" unless number == 1}"
        when :unknown then "unknown"
        when :not_observed then "not observed"
        else "with no counterexample"
        end
      end

      # Counterexamples first, as `hallmark check` prints them, then a note
      # on each verdict that is neither a pass nor a finding.
      def details
        order = %i[counterexample unknown not_observed none]
        verdicts = @results.map(&:verdict)
        lines = @results.sort_by.with_index { |result, index| [order.index(result.verdict) || 0, index] }
                        .flat_map(&:lines)
        lines << "" << UNKNOWN_NOTE if verdicts.include?(:unknown)
        lines << "" << NOT_OBSERVED_NOTE if verdicts.empty? || verdicts.include?(:not_observed)
        lines.join("\n")
      end
    end

    # `satisfy_catalog`: every known rule of the policy has no counterexample
    # within scope.
    class SatisfyCatalog < Matcher
      def description = "satisfy the catalog within scope #{scope}"

      private

      def expectation = "satisfy the catalog (no counterexample within scope #{scope} for any rule)"
    end

    # `have_no_counterexample(:update?)`: one rule's guard, checked on its own.
    class HaveNoCounterexample < Matcher
      def initialize(rule, mapping: nil, stamps: nil, root: nil, solver: nil)
        super(mapping: mapping, stamps: stamps, root: root, solver: solver)
        @rule = rule.to_s
      end

      def description = "have no counterexample for #{@rule} within scope #{scope}"

      private

      def target = "#{@policy}##{@rule}"
      def rule_names = [@rule]
    end

    # Included in every example group by `require "hallmark/rspec"`.
    module Matchers
      def satisfy_catalog = SatisfyCatalog.new(**hallmark_options)

      def have_no_counterexample(rule) = HaveNoCounterexample.new(rule, **hallmark_options)

      private

      # `let(:hallmark_mapping)`, `let(:hallmark_stamps)` and
      # `let(:hallmark_root)` override the configured mapping, stamps and the
      # app root whose policy code is read, for one example group.
      def hallmark_options = %i[mapping stamps root].to_h { |option| [option, hallmark_let(:"hallmark_#{option}")] }

      def hallmark_let(name) = respond_to?(name) ? public_send(name) : nil
    end

    # Included in groups tagged `:hallmark`: the subject is the policy the
    # tagged group describes, as a class or a name, in nested groups too
    # (RSpec's implicit subject would build an instance, or take a nested
    # group's own description).
    module PolicySubject
      def self.included(group)
        policy = group.described_class || group.description
        group.subject { policy }
      end
    end
  end
end

Hallmark::RSpec.install(RSpec.configuration) if defined?(RSpec.configuration)
