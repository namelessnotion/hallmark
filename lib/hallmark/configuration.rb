# typed: strict
# frozen_string_literal: true

module Hallmark
  # Global settings. Every value can also come from the environment so CI can
  # configure Hallmark without code changes.
  class Configuration
    # SPACE found every bug it reported at scope 3; 5 leaves headroom while
    # keeping each check to a few seconds.
    DEFAULT_SCOPE = 5
    # Seconds for one CLI run (every check) or one sidecar check.
    DEFAULT_TIMEOUT = 120
    # Megabytes of heap for the sidecar JVM (docs/PLAN.md, "Solver limits").
    DEFAULT_SIDECAR_HEAP = 512

    # Solver backends: `cli` runs `alloy exec` once per analysis; `sidecar`
    # keeps one JVM running Alloy for the whole process.
    SOLVERS = %i[cli sidecar].freeze
    # SAT solvers bundled in the Alloy jar that Hallmark documents.
    SAT_SOLVERS = %w[sat4j minisat glucose].freeze

    # Where collectors write stamps, relative to the app root.
    DEFAULT_STAMPS = "tmp/hallmark"

    # Runtime modes (docs/PLAN.md, "Runtime modes and performance budget").
    # Only `test` exists so far: collectors on, stamps from the test suite.
    MODES = %w[test off].freeze

    attr_accessor :alloy_jar, :java, :scope, :timeout, :sat_solver, :sidecar_heap, :stamps, :run, :root, :extract
    attr_writer :sidecar_jar
    attr_reader :mapping, :mode, :solver

    def initialize
      @alloy_jar = ENV.fetch("HALLMARK_ALLOY_JAR") { default_jar_path }
      @sidecar_jar = nil
      @sidecar_heap = Integer(ENV.fetch("HALLMARK_SIDECAR_HEAP", DEFAULT_SIDECAR_HEAP))
      @java = ENV.fetch("HALLMARK_JAVA", "java")
      @scope = Integer(ENV.fetch("HALLMARK_SCOPE", DEFAULT_SCOPE))
      @timeout = Integer(ENV.fetch("HALLMARK_TIMEOUT", DEFAULT_TIMEOUT))
      @sat_solver = ENV.fetch("HALLMARK_SAT_SOLVER", "sat4j")
      @solver = :cli
      @solver_chosen = false
      if (backend = ENV.fetch("HALLMARK_SOLVER", nil))
        self.solver = backend
      end
      @stamps = ENV.fetch("HALLMARK_STAMPS", DEFAULT_STAMPS)
      # The run analyses read from a stamp directory; nil reads the newest.
      # Collectors name the run they write from HALLMARK_RUN too
      # (`StampStore`), else from the time.
      @run = ENV.fetch("HALLMARK_RUN", nil)
      # The app whose policy code the extractor reads; the Railtie and the
      # CLI set it. HALLMARK_EXTRACT=off checks stamps and hand-written
      # guards only.
      @root = ENV.fetch("HALLMARK_ROOT") { Dir.pwd }
      @extract = ENV.fetch("HALLMARK_EXTRACT", "on") != "off"
      @mapping = nil
      @mode = nil
      self.mode = ENV.fetch("HALLMARK_MODE", nil)
    end

    # The app's mapping, which the collectors read facts through.
    # `Hallmark.analyze` starts from a copy of it, so an analysis never changes
    # it. Calling `map` again adds to the same mapping.
    def map(&)
      mapping = @mapping ||= Mapping.new
      mapping.instance_eval(&)
      mapping
    end

    # nil lets the Railtie decide: collectors on in the Rails test environment.
    def mode=(value)
      value = value&.to_s
      if value && !MODES.include?(value)
        raise ConfigurationError,
              "mode must be one of #{MODES.join(", ")}, not #{value}"
      end

      @mode = value
    end

    # `:cli` or `:sidecar`. HALLMARK_SOLVER named the SAT solver before the
    # sidecar existed, so a SAT solver name gets a pointer to its new variable.
    def solver=(value)
      name = value.to_s.downcase
      if SAT_SOLVERS.include?(name)
        raise ConfigurationError, "solver picks the backend (#{SOLVERS.join(" or ")}); " \
                                  "set the SAT solver with HALLMARK_SAT_SOLVER=#{name} or `c.sat_solver`"
      end
      unless (backend = SOLVERS.find { |solver| solver.to_s == name })
        raise ConfigurationError, "solver must be one of #{SOLVERS.join(", ")}, not #{value}"
      end

      @solver = backend
      @solver_chosen = true
    end

    # Whether HALLMARK_SOLVER or `c.solver=` picked the backend. The RSpec
    # matchers prefer the sidecar unless one did.
    def solver_chosen? = @solver_chosen

    # HALLMARK_SIDECAR_JAR wins; the source digest is computed on first use only.
    def sidecar_jar = @sidecar_jar ||= ENV.fetch("HALLMARK_SIDECAR_JAR") { default_sidecar_path }

    def default_jar_path = File.join(cache_dir, "alloy-#{ALLOY_VERSION}.jar")

    # Named by a digest of the Java sources, so a changed sidecar is rebuilt
    # rather than run stale.
    def default_sidecar_path = File.join(cache_dir, "hallmark-solver-#{SidecarInstaller.source_digest}.jar")

    def cache_dir
      File.join(ENV.fetch("XDG_CACHE_HOME") { File.join(Dir.home, ".cache") }, "hallmark")
    end
  end
end
