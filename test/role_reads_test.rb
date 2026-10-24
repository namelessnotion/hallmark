# frozen_string_literal: true

require "test_helper"

# The revocation lint (R1, phase 3 step 9) on test/fixtures/apps/revocation:
# which cached role reads it finds, which it finds cleared, where it starts
# and how far it walks; no Java.
class RoleReadsTest < Minitest::Test
  include Hallmark::Guard::DSL

  ROOT = File.join(HallmarkTestHelpers::FIXTURES, "apps", "revocation")

  # A mapping for one world of the fixture (`Shapes`, `Cleared`,
  # `Untouched`, `Starts`), whose terms name the methods to start from.
  def mapping(world, terms: [], roles: nil, roles_in: nil, &extra)
    Hallmark::Mapping.new.tap do |map|
      map.principal "#{world}::User", roles: roles
      map.tenant "#{world}::User", membership: "#{world}::Membership", roles_in: roles_in
      map.current_tenant :seller
      terms.each { |source| map.term source, map.role(:admin, tenant: :current) }
      map.instance_eval(&extra) if extra
    end
  end

  # The lint from the mapping's readers and terms alone; with `rules:`, also
  # from the rules the extractor reads (the fixture's Starts policies).
  def role_reads(map, rules: false)
    return Hallmark::Extractor.new(map, ROOT).role_reads if rules

    policies = Hallmark::Extractor::SourceIndex.new(ROOT, Hallmark::Extractor::DIRS)
    Hallmark::Extractor::RoleReads.new(map, ROOT, policies: policies, rules: [])
  end

  def lint_lines(reads) = reads.lints.map(&:location)
  def cache_at(reads, line) = reads.caches.find { |cache| cache.location.end_with?(":#{line}") }

  def shapes_file = "app/models/shapes/user.rb"

  def test_finds_rails_cache_reads_on_a_terms_path
    reads = role_reads(mapping("Shapes", terms: ["user.cached_role(seller)", "user.read_role"]))

    assert_equal ["#{shapes_file}:8", "#{shapes_file}:13"], lint_lines(reads)
    assert_equal "role/{}/{}", cache_at(reads, 8).key
    assert_equal "Rails.cache.read", cache_at(reads, 13).shape
    assert_match(/reached from term "user.cached_role\(seller\)" -> Shapes::User#cached_role/,
                 reads.lints.first.message)
    assert_equal "R1", reads.lints.first.kind
  end

  def test_finds_the_session_cookies_and_token_claims
    reads = role_reads(mapping("Shapes", terms: %w[user.session_role user.cookie_role user.token_role(x)]))

    shapes = reads.caches.map { |cache| [cache.shape, cache.key] }

    assert_equal [["session[...]", "role"], ["cookies.encrypted[...]", "team_role"], ["token claims", "role"]], shapes
    assert_match(/a copy no model callback can clear/, reads.lints.first.message)
  end

  def test_a_class_level_memo_of_a_parameter_is_a_cache_and_one_of_literals_is_not
    reads = role_reads(mapping("Shapes", terms: ["Shapes::User.roles_for(user)", "Shapes::User.nobody"]))

    assert_equal([["class-level memo @roles_by_user ||=", "#{shapes_file}:32"]],
                 reads.caches.map { |cache| [cache.shape, cache.location] })
  end

  def test_per_request_and_per_object_stores_are_not_caches
    terms = %w[user.instance_memo user.memoized user.request_store_roles user.safe_store_roles user.current_roles]
    reads = role_reads(mapping("Shapes", terms: terms))

    assert_empty reads.caches
    assert_empty reads.unread
  end

  def cleared(*methods, &)
    reads = role_reads(mapping("Cleared", terms: methods.map { |method| "user.#{method}" }, &))
    reads.caches.to_h { |cache| [cache.holder.delete_prefix("Cleared::User#"), cache.cleared] }
  end

  def test_after_commit_with_a_symbol_or_a_block_clears_a_matching_key
    found = cleared("symbol_role(seller)", "block_role")

    assert_match(/Cleared::Membership after_commit :forget/, found.fetch("symbol_role"))
    assert_match(/Cleared::Membership after_commit \(app/, found.fetch("block_role"))
  end

  def test_a_callback_reaching_the_users_own_deletion_clears_it
    assert_match(/after_destroy_commit :forget_destroyed/, cleared("destroyed_role").fetch("destroyed_role"))
  end

  def test_rolify_and_has_many_after_remove_clear
    found = cleared("rolify_role", "many_role")

    assert_match(/Cleared::User rolify clear_rolify/, found.fetch("rolify_role"))
    assert_match(/Cleared::User has_many clear_many/, found.fetch("many_role"))
  end

  def test_delete_matched_clears_by_glob
    assert_match(/forget_matching/, cleared("glob_role(seller)").fetch("glob_role"))
  end

  def test_a_versioned_key_is_fresh_when_the_membership_touches_the_user
    assert_match(/by touch: Cleared::Membership belongs_to :user, touch: true/,
                 cleared("versioned_role").fetch("versioned_role"))

    untouched = role_reads(mapping("Untouched", terms: ["user.versioned_role"]))

    assert_equal ["app/models/untouched/user.rb:5"], lint_lines(untouched)
  end

  def test_deleting_another_key_or_expiring_does_not_clear
    found = cleared("mismatched_role", "expiring_role")

    assert_nil found.fetch("mismatched_role")
    assert_nil found.fetch("expiring_role")
    reads = role_reads(mapping("Cleared", terms: ["user.expiring_role"]))

    assert_match(/expires_in: 1.hour\) outlives the request/, reads.lints.first.message)
    assert_match(/`expires_in:` bounds the staleness but does not clear it/, reads.lints.first.message)
  end

  def test_a_class_level_memo_reset_on_its_class_clears_it
    reads = role_reads(mapping("Cleared", terms: ["Cleared::User.memo_role(user)"]))

    assert_match(/Cleared::Membership after_save :reset_memo/, reads.caches.first.cleared)
    assert_empty reads.lints
  end

  def test_cache_ok_moves_a_read_to_coverage_with_its_reason
    map = mapping("Shapes", terms: ["user.cached_role(seller)"]) do
      cache_ok "Shapes::User#cached_role", reason: "a minute of staleness is fine"
    end
    reads = role_reads(map)

    assert_empty reads.lints
    assert_equal ["Shapes::User#cached_role (#{shapes_file}:8): a minute of staleness is fine"],
                 reads.accepted.map(&:to_s)
  end

  def test_cache_ok_naming_an_unknown_method_raises
    map = mapping("Shapes", terms: ["user.cached_role(seller)"]) { cache_ok "Shapes::User#nope", reason: "x" }

    error = assert_raises(Hallmark::ConfigurationError) { role_reads(map) }
    assert_match(/cache_ok Shapes::User#nope names no method/, error.message)
  end

  def test_cache_ok_must_name_a_method
    error = assert_raises(Hallmark::ConfigurationError) { Hallmark::Mapping.new.cache_ok("roles", reason: "x") }
    assert_match(/Class#method/, error.message)
  end

  def starts_file = "app/models/starts/user.rb"

  def test_starts_from_a_symbol_reader_and_a_lambda_read_where_it_is_written
    reads = role_reads(mapping("Starts", roles: :global_roles, roles_in: lambda { |user, seller|
      user.seller_roles(seller)
    }))

    assert_equal ["principal roles (:global_roles)", "tenant roles_in (a lambda)"], reads.starts.map(&:label)
    assert_equal ["#{starts_file}:9", "#{starts_file}:10"], lint_lines(reads)
    assert_equal "seller/{}/{}", cache_at(reads, 10).key
  end

  def test_a_lambda_sharing_its_line_is_not_read
    both = [->(user, seller) { user.seller_roles(seller) }, ->(user) { user.global_roles.to_a }]
    reads = role_reads(mapping("Starts", roles: both.last, roles_in: both.first))

    assert_empty reads.caches
    assert_equal(2, reads.unread.count { |unread| unread.call.end_with?("a lambda Hallmark could not read") })
  end

  def test_starts_from_a_pundit_rule_and_a_declarative_policy_condition
    map = mapping("Starts") do
      resource "Starts::Doc"
      resource "Starts::Project"
      rule "Starts::ProjectPolicy", :edit_project, op: :write
    end
    reads = role_reads(map, rules: true)

    assert_includes reads.starts.map(&:label), "Starts::DocPolicy#update?"
    assert_includes reads.starts.map(&:label), "Starts::ProjectPolicy condition(:admin)"
    assert_equal ["#{starts_file}:11", "#{starts_file}:12"], lint_lines(reads).sort
    assert_equal %w[Starts::DocPolicy#update? Starts::DocPolicy#admin? Starts::User#policy_role],
                 reads.starts.find { |start| start.label == "Starts::DocPolicy#update?" }.walked
  end

  def test_lists_what_it_cannot_follow
    reads = role_reads(mapping("Starts", terms: ["user.elsewhere", "user.missing_method"]))

    assert_equal ["Elsewhere::Roles.for", "Starts::User#undefined_here", "Starts::User#missing_method"],
                 reads.unread.map(&:call)
  end

  def test_follows_a_delegation_to_what_a_reader_builds
    reads = role_reads(mapping("Starts", terms: ["user.delegated_role"]))

    assert_equal ["app/models/starts/role_helper.rb:12"], lint_lines(reads)
    assert_equal %w[Starts::RoleHelper#delegated_role], reads.starts.first.walked
  end

  def test_follows_included_concerns
    assert_equal ["app/models/concerns/starts/roles.rb:5"],
                 lint_lines(role_reads(mapping("Starts", terms: ["user.concern_role"])))
  end

  def test_walks_at_most_four_calls_deep
    reads = role_reads(mapping("Starts", terms: ["user.deep1"]))

    assert_equal ["#{starts_file}:21"], lint_lines(reads)
    assert_equal %w[Starts::User#deep1 Starts::User#deep2 Starts::User#deep3 Starts::User#deep4 Starts::User#deep5],
                 reads.starts.first.walked
  end

  def test_reads_only_the_model_files_the_walk_needs
    reads = role_reads(mapping("Starts", terms: ["user.deep1"]))
    models = reads.instance_variable_get(:@models)

    assert models.scopes.key?("Starts::User")
    refute models.scopes.key?("Starts::Never")
    refute models.scopes.key?("Shapes::User")
  end

  def test_the_extractor_reports_r1_with_its_other_lints
    extractor = Hallmark::Extractor.new(mapping("Starts", terms: ["user.concern_role"]), ROOT)

    assert_equal %w[R1 R1], extractor.lints.map(&:kind)
    assert_equal "revocation hazard", Hallmark::Report.hazard(extractor.lints.first)
  end

  def test_nothing_to_start_from_gives_no_reading
    map = Hallmark::Mapping.new
    map.principal "Nobody::User"

    Dir.mktmpdir("hallmark-app") { |dir| assert_nil Hallmark::Extractor.new(map, dir).role_reads }
  end
end
