# frozen_string_literal: true

require_relative "lib/hallmark/version"

Gem::Specification.new do |spec|
  spec.name = "hallmark"
  spec.version = Hallmark::VERSION
  spec.authors = ["Anthony Byram"]
  spec.email = ["anthony@namelessnotion.com"]

  spec.summary = "Alloy-backed analysis of role-based authorization in Ruby apps."
  spec.description = <<~DESC
    Hallmark maps an application's authorization rules onto a catalog of
    access control patterns written in Alloy, then asks the Alloy Analyzer
    for counterexamples: a concrete user, role and record where an action is
    allowed that no intended pattern allows.
  DESC
  spec.homepage = "https://gitlab.com/namelessnotion/hallmark"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  # rbi/ carries the Sorbet signatures; srb and Tapioca pick it up from installed gems.
  # solver/ is the sidecar's Java source; `hallmark install-sidecar` builds it on the user's machine.
  spec.files = Dir["lib/**/*.rb", "rbi/**/*.rbi", "data/**/*.als", "solver/**/*.java", "bin/*", "README.md", "LICENSE"]
  spec.bindir = "bin"
  spec.executables = ["hallmark"]
  spec.require_paths = ["lib"]

  # A bundled gem since Ruby 3.0; declared so Bundler loads it.
  spec.add_dependency "rexml", "~> 3.2"
  # The extractor's parser. A default gem since Ruby 3.3, but 3.3.0 ships 0.19,
  # whose node API predates 1.0, and 3.2 ships none.
  spec.add_dependency "prism", ">= 1.2"
end
