# frozen_string_literal: true

module Hallmark
  # Global settings. Every value can also come from the environment so CI can
  # configure Hallmark without code changes.
  class Configuration
    # SPACE found every bug it reported at scope 3; 5 leaves headroom while
    # keeping each check to a few seconds.
    DEFAULT_SCOPE = 5
    DEFAULT_TIMEOUT = 120 # seconds for one solver run

    attr_accessor :alloy_jar, :java, :scope, :timeout, :solver

    def initialize
      @alloy_jar = ENV.fetch("HALLMARK_ALLOY_JAR") { default_jar_path }
      @java = ENV.fetch("HALLMARK_JAVA", "java")
      @scope = Integer(ENV.fetch("HALLMARK_SCOPE", DEFAULT_SCOPE))
      @timeout = Integer(ENV.fetch("HALLMARK_TIMEOUT", DEFAULT_TIMEOUT))
      @solver = ENV.fetch("HALLMARK_SOLVER", "SAT4J")
    end

    def default_jar_path
      cache = ENV.fetch("XDG_CACHE_HOME") { File.join(Dir.home, ".cache") }
      File.join(cache, "hallmark", "alloy-#{ALLOY_VERSION}.jar")
    end
  end
end
