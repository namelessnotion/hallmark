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

    # "test", "off", or nil to let the Railtie decide
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
    end

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
  end
end
