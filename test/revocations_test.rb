# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require_relative "support/revocation_shop"
require "hallmark/collectors/revocations"

# The test-mode revocations collector (phase 3 step 9) on Active Record and
# SQLite in memory: what a membership commit notes, how the next allow is
# marked, and what the collector leaves alone; no Java.
class RevocationsTest < Minitest::Test
  Revocations = Hallmark::Collectors::Revocations
  Shop = RevocationShop

  def setup
    super
    Shop.connect!
    Shop.reset!
  end

  def teardown
    Hallmark::Collectors.uninstall!
    Revocations.uninstall
    super
  end

  # Installs the collectors for the block and returns the stamp set.
  def collecting(revocations: true, **options)
    Dir.mktmpdir("hallmark-stamps") do |dir|
      mapping = Shop.map(Hallmark::Mapping.new, **options)
      Hallmark::Collectors.install!(mapping: mapping, store: Hallmark::StampStore.new(dir, run: "test"),
                                    revocations: revocations)
      yield
      Hallmark::Collectors.flush
      Hallmark::StampSet.files(dir).empty? ? Hallmark::StampSet.new : Hallmark::StampSet.load(dir)
    end
  end

  def noted = Revocations.noted.to_h
  def ref(record) = "#{record.class.base_class.name}:#{record.id}"

  def team
    seller = Shop::User.create!(name: "sam")
    admin = Shop::User.create!(name: "ann")
    [seller, admin, Shop::Membership.create!(user: admin, seller: seller, role: "admin")]
  end

  def decide(user, seller, record, allowed: true, list: false)
    Hallmark::Collectors.decision(policy: Shop::Policy.new(user, seller), rule: "update?", record: record,
                                  allowed: allowed, enforced: true, list: list)
  end

  def test_an_update_that_lowers_a_role_notes_the_pair
    collecting do
      seller, admin, membership = team
      membership.update!(role: "marketing")

      assert_equal({ ref(admin) => { ref(seller) => ["admin"] } }, noted)
    end
  end

  def test_a_destroy_revokes_every_role
    collecting do
      seller, admin, membership = team
      membership.destroy!

      assert_equal({ ref(admin) => { ref(seller) => ["admin"] } }, noted)
    end
  end

  def test_a_soft_delete_revokes_and_its_undo_grants_again
    collecting do
      seller, admin, membership = team
      membership.update!(deleted_at: Time.now)

      assert_equal({ ref(admin) => { ref(seller) => ["admin"] } }, noted)
      membership.update!(deleted_at: nil)

      assert_empty noted
    end
  end

  # Granting admin back forgets that it was revoked; marketing, held in
  # between, is revoked now.
  def test_a_grant_after_a_revocation_forgets_it
    collecting do
      seller, admin, membership = team
      membership.update!(role: "marketing")
      membership.update!(role: "admin")

      assert_equal({ ref(admin) => { ref(seller) => ["marketing"] } }, noted)
      membership.update!(role: "marketing", deleted_at: Time.now)
      membership.update!(role: "admin", deleted_at: nil)

      assert_equal({ ref(admin) => { ref(seller) => ["marketing"] } }, noted)
    end
  end

  def test_role_names_and_a_polymorphic_tenant
    names = ->(level) { { 30 => "developer", 10 => "guest" }.fetch(level) }
    collecting(membership: "RevocationShop::Member", within: :source, soft_delete: nil, roles: :access_level,
               role_names: names) do
      group = Shop::Group.create!(name: "core")
      user = Shop::User.create!(name: "ann")
      member = Shop::GroupMember.create!(user: user, source: group, access_level: 30)
      member.update!(access_level: 10)

      assert_equal({ ref(user) => { "RevocationShop::Group:#{group.id}" => ["developer"] } }, noted)
    end
  end

  def test_the_callback_runs_no_query_and_loads_no_association
    collecting do
      _, _, membership = team
      membership = Shop::Membership.find(membership.id)
      selects = []
      counter = ->(*, payload) { selects << payload[:sql] if payload[:sql].start_with?("SELECT") }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { membership.update!(role: "support") }

      assert_empty selects
      refute_predicate membership.association(:user), :loaded?
      refute_predicate membership.association(:seller), :loaded?
    end
  end

  def test_a_commit_inside_a_request_clears_its_role_reads
    collecting do
      seller, admin, membership = team
      link = Shop::Link.create!(user: seller)
      Hallmark::Collectors.within_entry_point("LinksController#update") do |request|
        decide(admin, seller, link)

        refute_empty request.roles
        membership.update!(role: "marketing")

        assert_empty request.roles
      end
    end
  end

  def test_nothing_is_watched_without_revocations
    collecting(revocations: false) do
      _, _, membership = team
      membership.update!(role: "marketing")

      assert_nil Revocations.noted
      assert_nil Hallmark::Collectors.facts.revoked
    end
  end

  def test_a_mapping_without_within_watches_nothing_and_says_why
    set = collecting(within: nil) do
      _, _, membership = team
      membership.update!(role: "marketing")

      assert_nil Revocations.noted
    end

    assert_equal ["tenant RevocationShop::User maps no `within:`, so the revocations collector watched no membership"],
                 set.unwatched.map(&:reason)
  end

  def test_a_membership_class_that_does_not_load_warns_once_and_watches_nothing
    set = nil
    assert_output(nil, /revocations not watched: RevocationShop::Nope did not load/) do
      set = collecting(membership: "RevocationShop::Nope") { assert_nil Revocations.noted }
    end

    assert_match(/RevocationShop::Nope did not load \(NameError\)/, set.unwatched.first.reason)
  end

  def test_the_pairs_are_cleared_before_each_example
    collecting do
      _, _, membership = team
      membership.update!(role: "marketing")
      example = Class.new { def before_setup = :ran }
      example.prepend(Revocations::FixtureReset)

      assert_equal :ran, example.new.before_setup
      assert_empty noted
      assert_includes ActiveRecord::TestFixtures.ancestors, Revocations::FixtureReset
    end
  end

  def stamps_after_downgrade(**options, &)
    collecting(**options) do
      seller, admin, membership = team
      link = Shop::Link.create!(user: seller)
      membership.update!(role: "marketing")
      instance_exec(seller, admin, link, &)
    end.stamps
  end

  def test_an_allow_lacking_a_revoked_role_is_marked
    stamps = stamps_after_downgrade { |seller, admin, link| decide(admin, seller, link) }

    assert_equal [["admin"]], stamps.map(&:after_revocation)
    assert_equal ["marketing"], stamps.first.current_roles
  end

  def test_denies_and_class_level_stamps_are_not_marked
    stamps = stamps_after_downgrade do |seller, admin, link|
      decide(admin, seller, link, allowed: false)
      decide(admin, seller, Shop::Link)
    end

    assert_equal [nil, nil], stamps.map(&:after_revocation)
  end

  def test_a_list_record_is_marked
    stamps = stamps_after_downgrade { |seller, admin, link| decide(admin, seller, link, list: true) }

    assert_equal [["admin"]], stamps.map(&:after_revocation)
  end

  def test_the_records_tenant_counts_as_well_as_the_current_one
    stamps = stamps_after_downgrade do |_seller, admin, link|
      other = Shop::User.create!(name: "kim")
      decide(admin, other, link)
    end

    assert_equal [["admin"]], stamps.map(&:after_revocation)
    assert_equal ["marketing"], stamps.first.record_roles
    refute stamps.first.in_current_tenant
  end

  def test_an_allow_still_holding_the_role_is_not_marked_and_is_noted
    stale = ->(_user, _seller) { ["admin"] }
    set = collecting(roles_in: stale) do
      seller, admin, membership = team
      link = Shop::Link.create!(user: seller)
      membership.update!(role: "marketing")
      decide(admin, seller, link)
    end

    assert_equal [nil], set.stamps.map(&:after_revocation)
    assert_equal([["update?", ["admin"]]], set.revoked_reads.map { |read| [read.rule, read.roles] })
  end

  def test_unmarked_lines_are_unchanged_and_marked_stamps_keep_apart
    plain = Hallmark::Stamp.new(policy: "LinkPolicy", rule: "update?", decision: "allow")
    marked = Hallmark::Stamp.new(**plain.to_h, after_revocation: ["admin"])

    refute_includes plain.to_json_line, "after_revocation"
    assert_includes marked.to_json_line, '"after_revocation":["admin"]'
    refute_equal plain, marked
    assert_equal [plain, marked], Hallmark::StampSet.parse([plain.to_json_line, marked.to_json_line]).stamps
  end

  def test_after_commit_runs_inside_transactional_tests_and_pairs_reset_per_example
    script = File.join(ROOT, "test", "support", "revocation_fixtures_run.rb")
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.join(ROOT, "lib"), "-I", File.join(ROOT, "test"),
                                           script)

    assert_predicate status, :success?, error
    assert_equal({ "before" => [["admin"]], "after" => {} }, JSON.parse(output.lines.last))
  end
end
