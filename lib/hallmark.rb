# frozen_string_literal: true

require_relative "hallmark/version"

# Hallmark checks an application's authorization rules against a catalog of
# access control patterns written in Alloy, and reports every exposure that
# no pattern allows, with a concrete counterexample.
module Hallmark
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class SolverError < Error; end

  DATA_DIR = File.expand_path("../data/hallmark", __dir__)
  CATALOG_PATH = File.join(DATA_DIR, "catalog.als")

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    # Declares an analysis and registers it so `hallmark check FILE` can run it.
    def analyze(name = "app", &)
      Analysis.build(name, &).tap { |analysis| analyses << analysis }
    end

    def analyses
      @analyses ||= []
    end

    def reset!
      @analyses = []
      @configuration = nil
    end
  end
end

require_relative "hallmark/configuration"
require_relative "hallmark/naming"
require_relative "hallmark/guard"
require_relative "hallmark/mapping"
require_relative "hallmark/exposure"
require_relative "hallmark/analysis"
require_relative "hallmark/model_builder"
require_relative "hallmark/receipt"
require_relative "hallmark/finding"
require_relative "hallmark/report"
require_relative "hallmark/solver/cli"
require_relative "hallmark/alloy_installer"
