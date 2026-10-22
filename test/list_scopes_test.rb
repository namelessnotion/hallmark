# frozen_string_literal: true

require "test_helper"
require_relative "support/fixture_solver"

# List scopes (phase 3 step 7): scope bodies read as a guard on each listed
# record, list checks in the model, list units in inference with their
# drift and coverage; no Java.
class ListScopesTest < Minitest::Test
  include Hallmark::Guard::DSL

  ROOT = File.join(HallmarkTestHelpers::FIXTURES, "apps", "lists")

  def self.map(lists)
    proc do
      principal "User", roles: :roles
      tenant "Organization", membership: "Membership", roles_in: :roles_in
      current_tenant :organization
      platform_role :admin
      resource "Project", tenant: :organization, public_if: :published?, lists: lists
      resource "Note", owner: :user
      resource "Item", owner: :user, tenant: :organization
      resource "Task", owner: :user
      resource "Board", owner: :user
      resource "Page"
      resource "Doc", tenant: :organization, owner: :user
      grant :member, :read, "Project"
      term "scope.published", public_record
      term "user.banned?", Hallmark::Guard.new(:never)
    end
  end

  def setup
    super
    Hallmark.configuration.root = ROOT
  end

  def never = Hallmark::Guard.new(:never)

  def mapping(lists: nil, &extra)
    mapping = Hallmark::Mapping.new
    mapping.instance_eval(&ListScopesTest.map(lists))
    mapping.instance_eval(&extra) if extra
    mapping.validate!
  end

  def lists(map = mapping) = Hallmark::Extractor.new(map, ROOT).lists.to_h { |list| [list.key, list] }

  def test_reads_pundit_scopes_through_branches_where_and_or
    project = lists.fetch("ProjectPolicy#Scope#resolve")

    assert_equal logged_in & (role(:admin) | (~role(:admin) & (member | public_record))), project.guard
    assert_equal ["Project", "app/policies/project_policy.rb:6"], [project.resource, project.location]
  end

  def test_owner_and_tenant_forms
    found = lists

    assert_equal logged_in & (owner & member), found.fetch("ItemPolicy#Scope#resolve").guard
    assert_equal logged_in & owner, found.fetch("TaskPolicy#Scope#resolve").guard
    assert_equal logged_in & owner, found.fetch("BoardPolicy#Scope#resolve").guard
  end

  # `where.not` on an attribute no term names, a join and a SQL string are
  # opaque, so their lists keep nothing for certain (docs/adr/0003).
  def test_what_cannot_be_read_is_opaque
    found = lists
    note = found.fetch("NotePolicy#Scope#resolve")

    assert_equal Hallmark::Guard.new(:never), note.lower
    assert_equal logged_in & owner, note.upper
    assert_equal(["archived: true", "scope.where(user_id: user.id).where.not(archived: true).joins(:tags)"],
                 note.opaque_leaves.map { |leaf| leaf.operands[0] })
    assert_equal Hallmark::Guard.new(:never), found.fetch("PagePolicy#Scope#resolve").lower
  end

  # The inherited ApplicationPolicy::Scope lists everything; its policy
  # names no resource.
  def test_the_base_scope_is_read_with_no_resource
    base = lists.fetch("ApplicationPolicy#Scope#resolve")

    assert_nil base.resource
    assert_equal logged_in, base.guard
  end

  def test_reads_action_policy_scopes_and_skips_params
    found = lists

    assert_equal in_current_tenant & public_record, found.fetch("DocPolicy#relation_scope").guard
    assert_equal owner, found.fetch("DocPolicy#relation_scope(:own)").guard
    assert_equal owner, found.fetch("DocPolicy#scope_for(:data, :mine)").guard
    assert_equal "app/policies/doc_policy.rb:14", found.fetch("DocPolicy#relation_scope").location
    refute(found.keys.any? { |key| key.include?("params") })
  end

  def test_a_term_for_the_whole_chain_wins
    map = mapping { term "scope.where(user: user).merge(scope.where(organization_id: user.organization_ids))", none }

    assert_equal logged_in, lists(map).fetch("ItemPolicy#Scope#resolve").guard
  end

  def test_names_and_plurals
    assert_equal(%w[links categories addresses boxes team_members],
                 %w[Link Category Address Box Shop::TeamMember].map { |name| Hallmark::Naming.plural(name) })
  end

  def analysis(stamps = [], lists: nil, &extra)
    map = mapping(lists: lists, &extra)
    Hallmark::Analysis.build("Lists", mapping: map) { stamps Hallmark::StampSet.new(stamps) }
  end

  def listed(policy:, rule:, resource:, entry_point: "ProjectsController#index", **facts)
    defaults = { class_level: false, enforced: false, decision: "allow", logged_in: true, roles: [], list: true }
    Hallmark::Stamp.new(**defaults, policy: policy, rule: rule, resource: resource, entry_point: entry_point,
                                    **facts)
  end

  def call(**) = listed(class_level: true, logged_in: true, **)

  def test_an_entry_point_that_listed_gets_a_list_exposure_from_the_code
    stamp = call(policy: "ProjectPolicy", rule: "Scope#resolve", resource: "Project")
    exposure = analysis([stamp]).exposures.find(&:list?)

    assert_equal ["ProjectsController#index", "list_ProjectsController_index_Project"],
                 [exposure.action, exposure.check_name]
    assert_equal lists.fetch("ProjectPolicy#Scope#resolve").guard, exposure.guard
    assert_equal ["app/policies/project_policy.rb:6"], exposure.locations
    assert_equal ["ProjectPolicy#Scope#resolve"], exposure.rules
  end

  # A list that can show another organization's projects, on a resource not
  # mapped `lists: :current_tenant`, is a question, not a failure.
  def test_a_list_across_tenants_is_a_question_unless_mapped
    stamp = call(policy: "ProjectPolicy", rule: "Scope#resolve", resource: "Project")

    assert_equal ["ProjectsController#index (Project)"], analysis([stamp]).inference.coverage.cross_tenant_lists
    assert_empty analysis([stamp], lists: :current_tenant).inference.coverage.cross_tenant_lists
  end

  # Records the list showed feed the guard as allow-stamps feed a rule's.
  def test_listed_records_feed_the_guard_and_calls_do_not
    where = { policy: "TaskPolicy", rule: "Scope#resolve", resource: "Task", entry_point: "TasksController#index" }
    stamps = [listed(**where, owner: true), call(**where)]
    unit = analysis(stamps).inference.units.find { |found| found.key == "TaskPolicy#Scope#resolve" }

    assert_equal 1, unit.stamps.size
    assert_equal 1, unit.calls.size
    assert_equal ["TasksController#index"], unit.entry_points
  end

  # A record the scope's code could never list is drift.
  def test_a_listed_record_outside_the_scopes_upper_bound_is_drift
    stamps = [listed(policy: "BoardPolicy", rule: "Scope#resolve", resource: "Board",
                     entry_point: "BoardsController#index", owner: false)]
    drift = analysis(stamps).inference.drift

    assert_equal ["BoardPolicy#Scope#resolve"], drift.map(&:rule)
    assert_predicate drift.first, :allow?
  end

  def test_a_scope_with_no_record_and_unreadable_code_has_nothing_to_check
    stamps = [call(policy: "PagePolicy", rule: "Scope#resolve", resource: "Page", entry_point: "PagesController#index")]
    inference = analysis(stamps).inference

    assert_includes inference.coverage.lists_unobserved, "PagePolicy#Scope#resolve"
    refute(inference.exposures.any?(&:list?))
  end

  def test_rule_check_checks_scopes_and_asks_about_tenants
    check = Hallmark::RuleCheck.new(mapping, Hallmark::StampSet.new, extractor: Hallmark::Extractor.new(mapping, ROOT))
    solver = FixtureSolver.new("list_ProjectPolicy_Scope_resolve_Project" => :none)
    result = check.check("ProjectPolicy", nil, solver: solver).fetch(0)

    assert_equal ["Scope#resolve", :none], [result.rule, result.verdict]
    assert_predicate result.exposure, :list?
    assert_match(/may list other tenants' records; declare `lists: :current_tenant` on Project/, result.lines.join)
  end

  def hand_lists(lists: nil)
    map = mapping(lists: lists)
    Hallmark::Analysis.build("Hand", mapping: map) do
      lists "ProjectsController#index", "Project", guard: member
      reads "ProjectsController#show", "Project", guard: member
    end
  end

  def test_a_list_check_in_the_model
    source = Hallmark::ModelBuilder.new(hand_lists).source

    assert_includes source, "-- ProjectsController#index: list Project, guard: member"
    assert_includes source, "pred lists_ProjectsController_index_Project[p: Principal, cur: Tenant, r: Project] " \
                            "{ (some rolesIn[p, r.tenant]) }"
    assert_includes source, "lists_ProjectsController_index_Project[p, cur, r] implies allowed[p, Read, r]\n"
    refute_includes source, "r.tenant in cur"
  end

  def test_lists_current_tenant_asks_for_the_current_tenant
    source = Hallmark::ModelBuilder.new(hand_lists(lists: :current_tenant)).source

    assert_includes source, "-- lists only the current tenant's records (lists: :current_tenant)"
    assert_includes source, "implies (allowed[p, Read, r] and r.tenant in cur)"
    # A read of one record is not a list.
    assert_includes source, "allows_ProjectsController_show_read_Project[p, cur, r] implies allowed[p, Read, r]\n"
  end

  def test_the_digest_covers_the_kind_and_the_mapping_option
    plain = hand_lists.exposures
    mapped = hand_lists(lists: :current_tenant)

    refute_equal plain.first.digest(mapping), mapped.exposures.first.digest(mapped.mapping)
    assert_equal plain.last.digest(mapping), mapped.exposures.last.digest(mapped.mapping)
  end

  def test_lists_needs_a_tenant
    error = assert_raises(Hallmark::ConfigurationError) { Hallmark::Mapping.new.resource("Note", lists: :current_tenant) }
    assert_match(/has `lists:` but no `tenant:`/, error.message)
  end

  # A G5 lint names the list checks of its type's scope_items.
  def test_a_g5_lint_links_to_the_list_checks_of_its_type
    lint = Hallmark::Extractor::DeclarativeTranslator::Lint.new(kind: "G5", location: "app/graphql/x.rb:3",
                                                                message: "scope off", subject: "Types::ProjectType")
    analysis = Hallmark::Analysis.build("G5", mapping: mapping) do
      lists "Query.projects", "Project", guard: member
    end
    analysis.exposures.first.rules = ["Types::ProjectType#scope_items"]

    assert_equal "scope off; where it runs, its lists are checked: list_Query_projects_Project",
                 Hallmark::Report.linked(lint, analysis).message
  end
end
