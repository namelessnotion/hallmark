# typed: strict

module Hallmark
  class SidecarInstaller
    sig { returns(T::Array[String]) }
    def self.sources; end

    sig { returns(String) }
    def self.source_digest; end

    sig { params(config: Configuration).void }
    def initialize(config = Hallmark.configuration)
      @java = T.let(T.unsafe(nil), String)
      @path = T.let(T.unsafe(nil), String)
      @alloy_jar = T.let(T.unsafe(nil), String)
    end

    sig { returns(String) }
    def install; end

    private

    sig { params(name: String).returns(String) }
    def tool(name); end

    # T.untyped because Sorbet rejects splatting an array of unknown length.
    sig { params(cmd: T.untyped).void }
    def run(cmd); end
  end
end
