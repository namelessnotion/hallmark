# frozen_string_literal: true

# Runs two Minitest examples with ActiveRecord::TestFixtures and
# transactional tests, the revocations collector installed, and prints what
# each saw as JSON: the first downgrades a membership inside the fixture
# transaction (after_commit still runs), the second, which runs after it,
# finds the pairs cleared by `before_setup`. Run by test/revocations_test.rb
# in a child process, so Minitest and Active Record state stay apart.

require "json"
require "tmpdir"
require "minitest"
require "active_record"
require "active_record/fixtures"
require "hallmark"
require "support/revocation_shop"

RevocationShop.connect!
# What each example saw.
RESULTS = Struct.new(:before, :after).new

# Two examples, in order.
class RevocationFixturesTest < Minitest::Test
  include ActiveRecord::TestFixtures

  self.fixture_paths = []
  self.use_transactional_tests = true
  i_suck_and_my_tests_are_order_dependent!

  def test_first
    seller = RevocationShop::User.create!(name: "sam")
    admin = RevocationShop::User.create!(name: "ann")
    membership = RevocationShop::Membership.create!(user: admin, seller: seller, role: "admin")
    membership.update!(role: "marketing")
    RESULTS.before = Hallmark::Collectors::Revocations.noted.to_h.values.flat_map(&:values)
  end

  def test_second
    RESULTS.after = Hallmark::Collectors::Revocations.noted.to_h
  end
end

Dir.mktmpdir("hallmark-stamps") do |dir|
  Hallmark::Collectors.install!(mapping: RevocationShop.map(Hallmark::Mapping.new),
                                store: Hallmark::StampStore.new(dir, run: "fixtures"), revocations: true)
  Minitest.run(["--seed", "1"])
end
puts JSON.generate(RESULTS.to_h)
