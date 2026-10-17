# frozen_string_literal: true

require "test_helper"
require "hallmark/rspec"
require_relative "collectors/shop_people"
require_relative "support/fixture_solver"

# The matchers as plain objects, without RSpec or Java: passing, failing with
# the finding explained, unknown, a rule with no observed allow, and where
# the mapping, stamps and solver come from. test/rspec_run_test.rb runs them
# inside RSpec.
class RSpecMatchersTest < Minitest::Test
  include ShopPeople

  POLICY = ApShop::LinkPolicy
  UPDATE = "safe_ApShop_LinkPolicy_update_write_Shop_Link"

  def teardown
    Hallmark::RSpec.close
    super
  end

  def mapping(&block)
    mapping = Shop.map(Hallmark::Mapping.new)
    mapping.instance_eval(&block) if block
    mapping
  end

  # edit? and update? allowed (update? across sellers, M2); destroy? only raised.
  def stamps
    @stamps ||= collect do
      Shop.request(ApShop::LinksController, :edit, user: @ann, seller: @ann, link: @ann_link)
      Shop.request(ApShop::LinksController, :update, user: @ada, seller: @ann, link: @bob_link)
      assert_raises(KeyError) do
        Shop.request(ApShop::LinksController, :destroy, user: @ada, seller: @ann, link: @ann_link)
      end
    end
  end

  def matcher(rule, solver, **options)
    options = { mapping: mapping, stamps: stamps, solver: solver }.merge(options)
    rule ? Hallmark::RSpec::HaveNoCounterexample.new(rule, **options) : Hallmark::RSpec::SatisfyCatalog.new(**options)
  end

  def refute_overclaims(message)
    refute_match(/\bsafe\b|verified|proved?\b/i, message)
  end

  def test_passes_when_the_rule_has_no_counterexample
    check = matcher(:edit?, FixtureSolver.new)

    assert check.matches?(POLICY)
    assert_equal "have no counterexample for edit? within scope 5", check.description
  end

  def test_fails_with_the_finding_in_app_terms
    check = matcher(:update?, FixtureSolver.new(UPDATE => :counterexample))

    refute check.matches?(POLICY)
    message = check.failure_message
    finding = check.results.first.finding
    assert_equal "expected ApShop::LinkPolicy#update? to have no counterexample within scope 5; " \
                 "1 counterexample in 1 rule:\n\n#{Hallmark::Report.finding_lines(finding).join("\n")}", message
    assert_includes message, "inferred from 1 allow-stamp of ApShop::LinkPolicy#update?"
    refute_overclaims message
  end

  def test_an_unknown_fails_and_says_so
    check = matcher(:update?, FixtureSolver.new(UPDATE => "timed out after 10 s"))

    refute check.matches?(POLICY)
    refute check.does_not_match?(POLICY)
    message = check.failure_message
    assert_includes message, "1 unknown in 1 rule"
    assert_includes message, "??    ApShop::LinkPolicy#update? (write Shop::Link): unknown, timed out after 10 s"
    assert_includes message, Hallmark::RSpec::Matcher::UNKNOWN_NOTE
    refute_overclaims message
  end

  def test_a_rule_with_no_observed_allow_fails_as_not_observed
    solver = FixtureSolver.new
    check = matcher(:destroy?, solver)

    refute check.matches?(POLICY)
    refute check.does_not_match?(POLICY)
    message = check.failure_message
    assert_includes message,
                    "--    ApShop::LinkPolicy#destroy?: not observed, no allow-stamp was recorded (1 deny-stamp)"
    assert_includes message, Hallmark::RSpec::Matcher::NOT_OBSERVED_NOTE
    assert_empty solver.models
  end

  def test_satisfy_catalog_checks_every_known_rule
    check = matcher(nil, FixtureSolver.new(UPDATE => :counterexample))

    refute check.matches?(POLICY)
    message = check.failure_message
    assert_match(/\Aexpected ApShop::LinkPolicy to satisfy the catalog \(no counterexample within scope 5 for any rule\); 1 counterexample, 1 not observed, 1 with no counterexample in 3 rules:\n\nFAIL  ApShop::LinkPolicy#update\?/, message) # rubocop:disable Layout/LineLength
    assert_operator message.index("--    ApShop::LinkPolicy#destroy?"), :<, message.index("ok    ApShop::LinkPolicy#edit?")
    assert_equal "satisfy the catalog within scope 5", check.description
  end

  def test_satisfy_catalog_passes_when_no_rule_has_a_counterexample
    written = mapping { rule ApShop::LinkPolicy, :destroy?, guard: role(:owner, tenant: :current) & in_current_tenant }

    assert matcher(nil, FixtureSolver.new, mapping: written).matches?(POLICY)
  end

  def test_satisfy_catalog_fails_when_no_rule_is_known
    check = matcher(nil, FixtureSolver.new)

    refute check.matches?(PunditShop::LinkPolicy)
    assert_includes check.failure_message,
                    "no rules of PunditShop::LinkPolicy were stamped or have a hand-written guard"
  end

  def test_not_to_passes_only_on_a_counterexample
    assert matcher(:update?, FixtureSolver.new(UPDATE => :counterexample)).does_not_match?(POLICY)

    check = matcher(:edit?, FixtureSolver.new)
    refute check.does_not_match?(POLICY)
    assert_equal "expected ApShop::LinkPolicy#edit? to have a counterexample within scope 5; " \
                 "1 with no counterexample in 1 rule:\n\nok    ApShop::LinkPolicy#edit? (read Shop::Link)",
                 check.failure_message_when_negated
  end

  def test_takes_a_policy_class_an_instance_or_a_name
    [POLICY, POLICY.new(nil, user: nil, seller: nil), "ApShop::LinkPolicy", :"ApShop::LinkPolicy"].each do |actual|
      check = matcher(:edit?, FixtureSolver.new)

      assert check.matches?(actual), "#{actual.inspect} should name ApShop::LinkPolicy"
    end
  end

  # What `let(:hallmark_mapping)` and `let(:hallmark_stamps)` provide in RSpec
  def test_example_group_lets_override_the_mapping_and_stamps
    group = Class.new do
      include Hallmark::RSpec::Matchers

      attr_reader :hallmark_mapping, :hallmark_stamps

      def initialize(mapping, stamps)
        @hallmark_mapping = mapping
        @hallmark_stamps = stamps
      end
    end
    Hallmark::RSpec.solver = FixtureSolver.new(UPDATE => :counterexample)
    example = group.new(mapping, stamps)

    assert example.have_no_counterexample(:edit?).matches?(POLICY)
    refute example.satisfy_catalog.matches?(POLICY)
  end

  def test_stamps_can_be_a_path
    Dir.mktmpdir do |dir|
      path = File.join(dir, "stamps.jsonl")
      File.write(path, stamps.stamps.map(&:to_json_line).join("\n"))

      assert matcher(:edit?, FixtureSolver.new, stamps: path).matches?(POLICY)
    end
  end

  def test_mapping_comes_from_the_configuration_or_config_hallmark_rb
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        assert_raises(Hallmark::ConfigurationError) { Hallmark::RSpec.mapping }

        FileUtils.mkdir_p("config")
        File.write("config/hallmark.rb", 'Hallmark.configure { |c| c.map { resource "Post", owner: :author } }')

        assert_equal ["Post"], Hallmark::RSpec.mapping.resources.keys
        assert_same Hallmark.configuration.mapping, Hallmark::RSpec.mapping
      end
    end
  end

  # While the collectors record, the matchers read the run in progress (not
  # a later-named one); afterwards, the run written last in `c.stamps`.
  def test_stamps_come_from_the_run_being_recorded
    current = nil
    collect do
      Shop.request(ApShop::LinksController, :edit, user: @ann, seller: @ann, link: @ann_link)
      dir = Hallmark::Collectors.store.dir
      File.write(File.join(dir, "stamps-zzz-1.jsonl"), "")
      current = Hallmark::RSpec.stamps
      Hallmark.configuration.stamps = dir
    end

    assert_equal([%w[ApShop::LinkPolicy edit?]], current.stamps.map { |stamp| [stamp.policy, stamp.rule] })
  end

  def test_stamps_are_empty_when_none_were_recorded
    Hallmark.configuration.stamps = File.join(Dir.tmpdir, "hallmark-none-#{Process.pid}")

    assert_empty Hallmark::RSpec.stamps.stamps
  end

  def test_prefers_the_sidecar_and_falls_back_to_the_cli
    Hallmark.configuration.sidecar_jar = File.join(Dir.tmpdir, "no-such-sidecar.jar")

    assert_instance_of Hallmark::Solver::CLI, Hallmark::RSpec.solver
  end

  def test_a_chosen_backend_wins
    refute_predicate Hallmark.configuration, :solver_chosen?
    Hallmark.configure { |config| config.solver = :sidecar }

    assert_predicate Hallmark.configuration, :solver_chosen?
    assert_instance_of Hallmark::Solver::Sidecar, Hallmark::RSpec.solver
  end

  def test_uses_the_sidecar_when_it_is_built
    require_sidecar!

    assert_instance_of Hallmark::Solver::Sidecar, Hallmark::RSpec.solver
  end

  def test_close_stops_the_shared_backend
    solver = FixtureSolver.new
    Hallmark::RSpec.solver = solver
    Hallmark::RSpec.close

    assert_predicate solver, :closed?
  end
end
