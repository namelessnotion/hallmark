# frozen_string_literal: true

require "test_helper"

# Guards read from policy code (docs/adr/0003), on the hand-written shop
# policies in test/fixtures/apps; no Java.
class ExtractorTest < Minitest::Test
  include Hallmark::Guard::DSL

  PUNDIT = File.join(HallmarkTestHelpers::FIXTURES, "apps", "shop")
  ACTION_POLICY = File.join(HallmarkTestHelpers::FIXTURES, "apps", "shop_action_policy")

  def mapping
    mapping = Hallmark::Mapping.new
    mapping.instance_eval do
      tenant "User", membership: "TeamMembership", self: :owner, roles_in: :team_roles_for
      current_tenant :seller
      platform_role :staff
      resource "Link", tenant: :user, permits: :collaborator_for?
      resource "PublicPage"
      term "user.role_owner_for?(seller)", role(:owner, tenant: :current)
      term "user.role_admin_for?(seller)", role(:admin, tenant: :current)
      term "user.role_marketing_for?(seller)", role(:marketing, tenant: :current)
    end
    mapping
  end

  def extract(root, policy, rule) = Hallmark::Extractor.new(mapping, root).fetch(policy, rule)

  def team = role(:owner, tenant: :current) | role(:admin, tenant: :current)
  def index_guard = team | role(:marketing, tenant: :current)
  def update_guard = permitted | (~permitted & (in_current_tenant & team))

  # The constructor raises without a user, so every rule starts with
  # logged_in; sibling rules and private helpers are read in place.
  def test_reads_pundit_rules_through_helpers_and_siblings
    show = extract(PUNDIT, "LinkPolicy", "show?")

    assert_equal logged_in & index_guard, show.guard
    assert_predicate show, :exact?
    assert_equal "Link", show.resource
    assert_equal "app/policies/link_policy.rb:21", show.location
  end

  def test_early_returns_split_the_rest_of_the_body
    assert_equal logged_in & update_guard, extract(PUNDIT, "LinkPolicy", "update?").guard
    assert_equal logged_in & (role(:staff) | (~role(:staff) & update_guard)),
                 extract(PUNDIT, "LinkPolicy", "edit?").guard
    assert_equal logged_in & (in_current_tenant & role(:owner, tenant: :current)),
                 extract(PUNDIT, "LinkPolicy", "archive?").guard
  end

  # `when_record { ... }` binds the block; a record is never a class here.
  def test_helpers_called_with_a_block_read_the_block
    assert_equal logged_in & (in_current_tenant & team), extract(PUNDIT, "LinkPolicy", "destroy?").guard
  end

  def test_locals_read_as_what_they_were_assigned
    assert_equal logged_in & (in_current_tenant & team), extract(PUNDIT, "LinkPolicy", "publish?").guard
  end

  def test_super_reads_the_parents_rule
    guard = extract(PUNDIT, "Admin::LinkPolicy", "update?")

    assert_equal logged_in & (update_guard | role(:staff)), guard.guard
    assert_equal "Link", guard.resource
  end

  # `allow_anonymous!` sets the class attribute the constructor reads.
  def test_class_attributes_set_in_the_class_body
    assert_equal none, extract(PUNDIT, "PublicPagePolicy", "show?").guard
  end

  def test_unread_calls_stay_opaque_with_their_line
    preview = extract(PUNDIT, "LinkPolicy", "preview?")
    leaf = preview.opaque_leaves.fetch(0)

    refute_predicate preview, :exact?
    assert_equal ["user.feature_enabled?(:previews)", "app/policies/link_policy.rb:43"], leaf.operands
    assert_equal Hallmark::Guard.new(:never), preview.lower
    assert_equal logged_in & index_guard, preview.upper
  end

  def test_recursion_is_opaque
    assert_equal ["loop?", "app/policies/link_policy.rb:46"],
                 extract(PUNDIT, "LinkPolicy", "loop?").opaque_leaves.fetch(0).operands
  end

  def test_rules_are_public_question_methods_without_arguments
    rules = Hallmark::Extractor.new(mapping, PUNDIT).rules.select { |rule| rule.policy == "LinkPolicy" }.map(&:rule)

    assert_equal %w[archive? destroy? edit? index? loop? preview? publish? show? update?], rules
  end

  # Pre-checks run first, in order, with `only:` and `except:`; `deny!` and
  # `allow!` exit.
  def test_reads_action_policy_pre_checks_and_exits
    staff_first = ->(guard) { logged_in & (role(:staff) | (~role(:staff) & guard)) }

    assert_equal logged_in & index_guard, extract(ACTION_POLICY, "LinkPolicy", "index?").guard
    assert_equal staff_first.call(update_guard), extract(ACTION_POLICY, "LinkPolicy", "update?").guard
    assert_equal staff_first.call(update_guard), extract(ACTION_POLICY, "LinkPolicy", "edit?").guard
  end

  def test_action_policy_aliases_and_default_rule
    assert_equal logged_in & (role(:staff) | (~role(:staff) & index_guard)),
                 extract(ACTION_POLICY, "LinkPolicy", "show?").guard
    # Not defined: the default rule, manage?, which the base class denies;
    # the staff pre-check still allows.
    destroy = extract(ACTION_POLICY, "LinkPolicy", "destroy?")

    assert_equal logged_in & role(:staff), destroy.guard
    assert_equal "LinkPolicy (default rule)", destroy.location
  end

  def test_pundit_policies_answer_no_undefined_rule
    assert_nil extract(PUNDIT, "LinkPolicy", "destroy_all?")
    assert_nil extract(PUNDIT, "MissingPolicy", "show?")
  end

  def test_normalizes_spacing_parentheses_self_and_instance_variables
    assert_equal "record.user != seller", Hallmark::Extractor::Terms.normalize("(@record.user)  !=  self.seller")
    assert_equal "user.role_admin_for?(seller)", Hallmark::Extractor::Terms.normalize("user.role_admin_for?( @seller )")
  end

  def test_loads_only_where_there_is_policy_code
    assert_instance_of Hallmark::Extractor, Hallmark::Extractor.load(mapping, PUNDIT)
    assert_nil Hallmark::Extractor.load(mapping, HallmarkTestHelpers::FIXTURES)
    Hallmark.configuration.extract = false

    assert_nil Hallmark::Extractor.load(mapping, PUNDIT)
  end

  def test_mapping_rejects_a_term_that_is_not_a_guard
    assert_raises(Hallmark::ConfigurationError) { Hallmark::Mapping.new.term("user.admin?", :admin) }
  end
end
