# typed: strict

module Hallmark
  class AlloyInstaller
    URL = T.let(T.unsafe(nil), String)

    sig { params(path: String).returns(String) }
    def install(path = Hallmark.configuration.alloy_jar); end

    private

    sig { params(uri: URI::Generic, destination: String, redirects: Integer).void }
    def download(uri, destination, redirects = MAX_REDIRECTS); end

    sig { params(path: String).returns(String) }
    def digest(path); end
  end
end
