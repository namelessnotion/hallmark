# typed: strict
# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "tmpdir"

module Hallmark
  # Builds the solver sidecar from solver/src with the JDK's javac and jar,
  # against the pinned Alloy jar (which already holds every Alloy class and
  # the native SAT solvers), so it needs no download of its own. The jar is
  # named by a digest of the sources and lands next to the Alloy jar.
  class SidecarInstaller
    # Alloy 6.2 targets Java 17, and so does the sidecar.
    JAVA_RELEASE = "17"

    def self.sources = Dir.glob(File.join(SIDECAR_SOURCE, "**", "*.java"))

    def self.source_digest
      digest = Digest::SHA256.new
      sources.map { |path| path.delete_prefix(SIDECAR_SOURCE) }.each do |name|
        digest << name << "\0" << File.read(File.join(SIDECAR_SOURCE, name)) << "\0"
      end
      digest.hexdigest[0, 12] || raise(Error, "empty digest")
    end

    def initialize(config = Hallmark.configuration)
      @java = config.java
      @path = config.sidecar_jar
      @alloy_jar = config.alloy_jar
    end

    def install
      return @path if File.file?(@path)
      unless File.file?(@alloy_jar)
        raise Error, "Alloy jar not found at #{@alloy_jar}; run `hallmark install-alloy` first"
      end

      FileUtils.mkdir_p(File.dirname(@path))
      Dir.mktmpdir("hallmark-sidecar") do |dir|
        classes = File.join(dir, "classes")
        run([tool("javac"), "--release", JAVA_RELEASE, "-encoding", "UTF-8", "-nowarn",
             "-cp", @alloy_jar, "-d", classes] + self.class.sources)
        partial = "#{@path}.part"
        run([tool("jar"), "--create", "--file", partial, "-C", classes, "."])
        File.rename(partial, @path)
      end
      @path
    end

    private

    # javac and jar sit next to java in a JDK; HALLMARK_JAVA may name that
    # java by path.
    def tool(name)
      return name unless @java.include?(File::SEPARATOR)

      File.join(File.dirname(@java), name)
    end

    def run(cmd)
      out, status = Open3.capture2e(*cmd)
      raise Error, "#{File.basename(cmd.first.to_s)} failed building the sidecar:\n#{out.strip}" unless status.success?
    rescue SystemCallError => e
      raise Error, "building the sidecar needs a JDK 17+ (#{cmd.first}: #{e.message})"
    end
  end
end
