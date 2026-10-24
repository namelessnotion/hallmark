# frozen_string_literal: true

# The revocation shop after the fix Hallmark points to: TeamMembership
# deletes the cached role after each commit, so the downgraded admin's
# second update is denied.
#
# Run: bundle exec ruby -Ilib examples/revocation_shop/scenario.rb fixed
#      bin/hallmark check examples/revocation_shop/hallmark_fixed.rb

require_relative "mapping"

root = File.join(__dir__, "fixed")
stamps = ENV.fetch("HALLMARK_STAMPS") { File.join(root, "tmp", "hallmark") }
run = ENV.fetch("HALLMARK_RUN", "scenario")
unless Hallmark::StampSet.files(stamps, run: run).any?
  raise Hallmark::ConfigurationError, "no stamps in #{stamps}; run examples/revocation_shop/scenario.rb fixed first"
end

Hallmark.analyze "Revocation shop (fixed)" do
  map { RevocationShopMapping.apply(self) }

  stamps Hallmark::StampSet.load(stamps, run: run), root: root
end
