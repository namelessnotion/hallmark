# typed: strict
# frozen_string_literal: true

require_relative "hallmark/version"
require_relative "hallmark/configuration"

# Hallmark checks an application's authorization rules against a catalog of
# access control patterns written in Alloy, and reports every exposure that
# no pattern allows, with a concrete counterexample.
module Hallmark
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class SolverError < Error; end

  DATA_DIR = File.expand_path("../data/hallmark", __dir__)
  CATALOG_PATH = File.join(DATA_DIR, "catalog.als")
  # Java sources of the solver sidecar, built by `hallmark install-sidecar`.
  SIDECAR_SOURCE = File.expand_path("../solver/src", __dir__)

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    # Declares an analysis and registers it so `hallmark check FILE` can run it.
    # It starts from a copy of the configured mapping (`c.map`), when there is
    # one, so its `map` never changes what the collectors read.
    def analyze(name = "app", &)
      Analysis.build(name, mapping: configuration.mapping, &).tap { |analysis| analyses << analysis }
    end

    def analyses
      @analyses ||= []
    end

    # The configured backend, shared by every analysis in this process so a
    # sidecar starts once.
    def solver
      @solver ||= Solver.build(configuration)
    end

    def reset!
      @solver&.close
      @solver = nil
      @analyses = []
      @configuration = nil
    end
  end
end

require_relative "hallmark/naming"
require_relative "hallmark/guard"
require_relative "hallmark/ops"
require_relative "hallmark/restriction"
require_relative "hallmark/mapping"
require_relative "hallmark/exposure"
require_relative "hallmark/stamp"
require_relative "hallmark/stamp_facts"
require_relative "hallmark/example"
require_relative "hallmark/sinks"
require_relative "hallmark/stamp_store"
require_relative "hallmark/coverage"
require_relative "hallmark/extractor"
require_relative "hallmark/drift"
require_relative "hallmark/unchecked_requests"
require_relative "hallmark/inference"
require_relative "hallmark/inference_routes"
require_relative "hallmark/analysis"
require_relative "hallmark/flag_model"
require_relative "hallmark/model_builder"
require_relative "hallmark/receipt"
require_relative "hallmark/witness_facts"
require_relative "hallmark/finding"
require_relative "hallmark/report"
require_relative "hallmark/sarif"
require_relative "hallmark/rule_check"
require_relative "hallmark/baseline"
require_relative "hallmark/watch"
require_relative "hallmark/solver"
require_relative "hallmark/solver/cli"
require_relative "hallmark/solver/child_process"
require_relative "hallmark/solver/sidecar"
require_relative "hallmark/alloy_installer"
require_relative "hallmark/sidecar_installer"
require_relative "hallmark/collectors"
require_relative "hallmark/railtie" if defined?(Rails::Railtie)
