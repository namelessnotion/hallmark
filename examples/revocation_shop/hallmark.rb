# frozen_string_literal: true

# Revocation shop: Storefront's domain on Active Record, where a seller's
# admin keeps editing products after being downgraded to marketing,
# because the app caches team roles across requests and nothing clears
# them (threat 9). The stamps come from scenario.rb, which boots the app
# with the collectors in test mode; the cache comes from reading the code.
# See README.md in this folder.
#
# Run: bundle exec ruby -Ilib examples/revocation_shop/scenario.rb   (writes the stamps)
#      bin/hallmark check examples/revocation_shop/hallmark.rb        (exits 1: one R1 lint, one stale access)

require_relative "mapping"

stamps = ENV.fetch("HALLMARK_STAMPS") { File.join(__dir__, "tmp", "hallmark") }
run = ENV.fetch("HALLMARK_RUN", "scenario")
unless Hallmark::StampSet.files(stamps, run: run).any?
  raise Hallmark::ConfigurationError, "no stamps in #{stamps}; run examples/revocation_shop/scenario.rb first"
end

Hallmark.analyze "Revocation shop" do
  map { RevocationShopMapping.apply(self) }

  stamps Hallmark::StampSet.load(stamps, run: run), root: __dir__
end
