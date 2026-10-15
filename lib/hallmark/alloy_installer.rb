# frozen_string_literal: true

require "digest"
require "fileutils"
require "net/http"

module Hallmark
  # Downloads the pinned Alloy release and refuses it unless the SHA-256
  # matches, so every machine and CI runner solves with the same jar.
  class AlloyInstaller
    URL = "https://github.com/AlloyTools/org.alloytools.alloy/releases/download/v#{ALLOY_VERSION}/org.alloytools.alloy.dist.jar".freeze
    SHA256 = "6b8c1cb5bc93bedfc7c61435c4e1ab6e688a242dc702a394628d9a9801edb78d"
    MAX_REDIRECTS = 5

    def install(path = Hallmark.configuration.alloy_jar)
      return path if File.file?(path) && digest(path) == SHA256

      FileUtils.mkdir_p(File.dirname(path))
      partial = "#{path}.part"
      download(URI(URL), partial)
      actual = digest(partial)
      unless actual == SHA256
        FileUtils.rm_f(partial)
        raise Error, "Alloy #{ALLOY_VERSION} checksum mismatch: expected #{SHA256}, got #{actual}"
      end

      File.rename(partial, path)
      path
    end

    private

    def download(uri, destination, redirects = MAX_REDIRECTS)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request_get(uri) do |response|
          case response
          when Net::HTTPRedirection
            raise Error, "too many redirects downloading Alloy" if redirects.zero?

            return download(URI(response["location"]), destination, redirects - 1)
          when Net::HTTPSuccess
            File.open(destination, "wb") { |file| response.read_body { |chunk| file.write(chunk) } }
          else
            raise Error, "downloading Alloy failed: HTTP #{response.code}"
          end
        end
      end
    end

    def digest(path) = Digest::SHA256.file(path).hexdigest
  end
end
