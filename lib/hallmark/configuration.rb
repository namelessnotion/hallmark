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

    # Runtime modes (docs/PLAN.md, "Runtime modes and performance budget"):
    # `test` collects from the test suite; `shadow` (staging, or production
    # behind a flag) and `sampled` (production) collect from live requests,
    # with a bounded queue, the routes recorded at boot, and ids when asked
    # for; `off` never collects.
    MODES = %w[test shadow sampled off].freeze
    COLLECTING = %w[test shadow sampled].freeze
    # The share of requests whose decisions `sampled` stamps, unless
    # HALLMARK_SAMPLE or `c.sample_rate` says otherwise; the other modes
    # stamp every one.
    SAMPLED_RATE = 0.01
    # Events a live process lets wait for the flusher before dropping them.
    LIVE_CAPACITY = 10_000
    # Characters an id key needs at least (`SecureRandom.hex(32)` gives 64).
    ID_KEY_MIN = 32
    # Where a deploy's revision is found, after HALLMARK_RUN: a REVISION file
    # in the app root (Capistrano), then these variables.
    REVISION_VARIABLES = %w[HEROKU_SLUG_COMMIT GIT_SHA].freeze

    attr_accessor :alloy_jar, :java, :scope, :timeout, :sat_solver, :sidecar_heap, :stamps, :run, :root, :extract,
                  :id_key
    attr_writer :sidecar_jar, :ids
    attr_reader :mapping, :mode, :solver, :sample_rate, :sink, :on_finding

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
      live_settings
    end

    # The app's mapping, which the collectors read facts through.
    # `Hallmark.analyze` starts from a copy of it, so an analysis never changes
    # it. Calling `map` again adds to the same mapping.
    def map(&)
      mapping = @mapping ||= Mapping.new
      mapping.instance_eval(&)
      mapping
    end

    # A restriction (threat 11) on the app's mapping, the same as `restrict`
    # inside `map`:
    #
    #   c.restrict "admins never read card numbers" do
    #     deny role: :admin, op: :read, resource: "PaymentMethod", fields: %i[number cvc]
    #   end
    def restrict(name, &)
      mapping = @mapping ||= Mapping.new
      mapping.restrict(name, &)
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

    # The share of requests (and of decisions outside a request) whose
    # decisions are stamped, from 0 to 1; nil leaves it to the mode.
    def sample_rate=(value)
      unless value.nil? || (value.is_a?(Numeric) && value.between?(0, 1))
        raise ConfigurationError, "sample_rate must be a number from 0 to 1, not #{value.inspect}"
      end

      @sample_rate = value&.to_f
    end

    def sample_rate_for(mode) = @sample_rate || (mode == "sampled" ? SAMPLED_RATE : 1.0)

    # Where stamps go: nil for files under `stamps`, a sink
    # (`Sinks::RedisStream.new(redis)`, anything with `write(line, run)`), or
    # a callable taking the line (and the run).
    def sink=(value)
      @sink = Sinks.build(value)
    end

    # Called by `hallmark watch` once per new event (a finding, an unchecked
    # entry point, drift, or a check that no longer fails), with a
    # `Watch::Event`; for alerts. An exception it raises is warned about and
    # the watch goes on.
    def on_finding=(callable)
      unless callable.nil? || callable.respond_to?(:call)
        raise ConfigurationError, "on_finding takes a callable (a lambda given the event), not a #{callable.class.name}"
      end

      @on_finding = callable
    end

    def ids? = @ids == true

    # The key ids are hashed with in `mode`, or nil when ids are off. Ids
    # are for tracing live requests: test mode refuses them, so stamps in
    # CI artifacts and fixtures stay id-free.
    def id_key_for(mode)
      return nil unless ids?
      raise ConfigurationError, "ids are for the shadow and sampled modes, not #{mode}" unless live?(mode)

      key = @id_key.to_s
      return key if key.length >= ID_KEY_MIN

      raise ConfigurationError, "ids need a key of at least #{ID_KEY_MIN} characters in HALLMARK_ID_KEY or " \
                                "`c.id_key` (for example `SecureRandom.hex(32)`)"
    end

    # Whether `mode` collects from live requests rather than a test suite.
    def live?(mode) = %w[shadow sampled].include?(mode)

    # The run collectors write in `mode`: HALLMARK_RUN (`c.run`), else in
    # the live modes the deploy's revision, so every process of a deploy
    # writes the same run, else the time. Test runs are named by time, so
    # each suite is a run of its own.
    def write_run(mode, root)
      named = run || (revision(root) if live?(mode))
      return named.to_s.gsub(/[^A-Za-z0-9_]/, "_") if named

      Time.now.utc.strftime("%Y%m%dT%H%M%S%LZ")
    end

    # The deploy's revision: a REVISION file in the app root, then
    # REVISION_VARIABLES; nil when none is set.
    def revision(root)
      file = File.join(root.to_s, "REVISION")
      if File.file?(file)
        text = File.read(file).strip
        return text unless text.empty?
      end
      REVISION_VARIABLES.each do |variable|
        value = ENV.fetch(variable, "").strip
        return value unless value.empty?
      end
      nil
    end

    # The store the collectors write through in `mode`: bounded in the live
    # modes, through `sink`, hashing ids when they are on.
    def stamp_store(mode, root)
      StampStore.new(stamps, run: write_run(mode, root), capacity: (LIVE_CAPACITY if live?(mode)), sink: sink,
                             id_key: id_key_for(mode))
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

    private

    # What the live modes read: the sample rate, the sink, and hashed ids
    # beside stamps (docs/adr/0004); and what `hallmark watch` calls.
    def live_settings
      @on_finding = nil
      @sample_rate = nil
      if (rate = ENV.fetch("HALLMARK_SAMPLE", nil))
        self.sample_rate = Float(rate)
      end
      @sink = nil
      @ids = ENV.fetch("HALLMARK_IDS", "off") == "on"
      @id_key = ENV.fetch("HALLMARK_ID_KEY", nil)
    end
  end
end
