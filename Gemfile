# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development do
  gem "minitest", "~> 5.20"
  gem "rake", "~> 13.0"
  # For `hallmark/rspec`'s matchers and examples/storefront's spec; users bring their own.
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.80", require: false
  gem "rubocop-minitest", require: false
  gem "rubocop-rake", require: false
  gem "ruby-lsp", require: false
  # Static checker only; signatures live in rbi/, so neither the gem nor its
  # users load sorbet-runtime.
  gem "sorbet", "~> 0.6", require: false
  # Generates RBIs for the gems below, which lib/'s collectors and Railtie reference.
  gem "tapioca", require: false
end

# The authorization libraries and Rails pieces the collectors hook into. The
# gem itself depends on none of them; the tests drive each one.
group :test do
  gem "actionpack", "~> 8.0"
  gem "action_policy", "~> 0.7"
  # The revocations collector's after_commit and transactional tests (phase 3
  # step 9); sqlite3 2.x installs precompiled, so CI needs no compiler.
  gem "activerecord", "~> 8.0"
  gem "declarative_policy", "~> 2.0"
  gem "grape", "~> 2.0"
  gem "graphql", "~> 2.4"
  gem "pundit", "~> 2.4"
  gem "railties", "~> 8.0"
  gem "sqlite3", "~> 2.0"
end
