# typed: strict

module Hallmark
  class Configuration
    sig { returns(String) }
    attr_accessor :alloy_jar

    sig { returns(String) }
    attr_accessor :java

    sig { returns(Integer) }
    attr_accessor :scope

    sig { returns(Integer) }
    attr_accessor :timeout

    # SAT solver inside Alloy: sat4j, minisat or glucose
    sig { returns(String) }
    attr_accessor :sat_solver

    # Backend: :cli or :sidecar
    sig { returns(Symbol) }
    attr_reader :solver

    # HALLMARK_SIDECAR_JAR, else the default path, computed on first use
    sig { returns(String) }
    def sidecar_jar; end

    sig { params(sidecar_jar: String).returns(String) }
    attr_writer :sidecar_jar

    # Megabytes
    sig { returns(Integer) }
    attr_accessor :sidecar_heap

    DEFAULT_STAMPS = T.let(T.unsafe(nil), String)
    SOLVERS = T.let(T.unsafe(nil), T::Array[Symbol])
    SAT_SOLVERS = T.let(T.unsafe(nil), T::Array[String])
    MODES = T.let(T.unsafe(nil), T::Array[String])
    COLLECTING = T.let(T.unsafe(nil), T::Array[String])
    REVISION_VARIABLES = T.let(T.unsafe(nil), T::Array[String])

    # The share of requests stamped; nil leaves it to the mode
    sig { returns(T.nilable(Float)) }
    attr_reader :sample_rate

    # Where stamps go: nil for files under `stamps`
    sig { returns(Sinks::Sink) }
    attr_reader :sink

    # The key ids are hashed with (HALLMARK_ID_KEY)
    sig { returns(T.nilable(String)) }
    attr_accessor :id_key

    sig { params(ids: T::Boolean).returns(T::Boolean) }
    attr_writer :ids

    # Directory the collectors write stamps to
    sig { returns(String) }
    attr_accessor :stamps

    # The run analyses read from a stamp directory (HALLMARK_RUN); nil for
    # the newest
    sig { returns(T.nilable(String)) }
    attr_accessor :run

    # The app root the extractor reads policy code under
    sig { returns(String) }
    attr_accessor :root

    # Whether to read guards from policy code (HALLMARK_EXTRACT=off: no)
    sig { returns(T::Boolean) }
    attr_accessor :extract

    sig { returns(T.nilable(Mapping)) }
    attr_reader :mapping

    # "test", "shadow", "sampled", "off", or nil to let the Railtie decide
    sig { returns(T.nilable(String)) }
    attr_reader :mode

    sig { void }
    def initialize
      @alloy_jar = T.let(T.unsafe(nil), String)
      @java = T.let(T.unsafe(nil), String)
      @scope = T.let(T.unsafe(nil), Integer)
      @timeout = T.let(T.unsafe(nil), Integer)
      @sat_solver = T.let(T.unsafe(nil), String)
      @solver = T.let(T.unsafe(nil), Symbol)
      @solver_chosen = T.let(T.unsafe(nil), T::Boolean)
      @sidecar_jar = T.let(T.unsafe(nil), T.nilable(String))
      @sidecar_heap = T.let(T.unsafe(nil), Integer)
      @stamps = T.let(T.unsafe(nil), String)
      @run = T.let(T.unsafe(nil), T.nilable(String))
      @root = T.let(T.unsafe(nil), String)
      @extract = T.let(T.unsafe(nil), T::Boolean)
      @mapping = T.let(T.unsafe(nil), T.nilable(Mapping))
      @mode = T.let(T.unsafe(nil), T.nilable(String))
      @sample_rate = T.let(T.unsafe(nil), T.nilable(Float))
      @sink = T.let(T.unsafe(nil), Sinks::Sink)
      @ids = T.let(T.unsafe(nil), T::Boolean)
      @id_key = T.let(T.unsafe(nil), T.nilable(String))
    end

    # Untyped: the value comes from the app's configuration file, and is checked
    sig { params(value: T.untyped).void }
    def sample_rate=(value); end

    sig { params(mode: String).returns(Float) }
    def sample_rate_for(mode); end

    sig { params(value: T.untyped).void }
    def sink=(value); end

    sig { returns(T::Boolean) }
    def ids?; end

    sig { params(mode: String).returns(T.nilable(String)) }
    def id_key_for(mode); end

    sig { params(mode: T.nilable(String)).returns(T::Boolean) }
    def live?(mode); end

    sig { params(mode: String, root: T.any(String, Pathname)).returns(String) }
    def write_run(mode, root); end

    sig { params(root: T.any(String, Pathname)).returns(T.nilable(String)) }
    def revision(root); end

    sig { params(mode: String, root: T.any(String, Pathname)).returns(StampStore) }
    def stamp_store(mode, root); end

    sig { params(blk: T.proc.bind(Mapping).void).returns(Mapping) }
    def map(&blk); end

    sig { params(value: T.nilable(T.any(String, Symbol))).void }
    def mode=(value); end

    sig { params(value: T.any(String, Symbol)).void }
    def solver=(value); end

    sig { returns(T::Boolean) }
    def solver_chosen?; end

    sig { returns(String) }
    def default_jar_path; end

    sig { returns(String) }
    def default_sidecar_path; end

    sig { returns(String) }
    def cache_dir; end

    private

    sig { void }
    def live_settings; end
  end
end
