# frozen_string_literal: true

require "test_helper"

# DeclarativePolicy abilities read from code (phase 2 step 4), on the
# hand-written project host in test/fixtures/apps/declarative_*: rules,
# `can?`, delegates, EE prepends, helper-built ability lists, record flags,
# conditional grants and the D3 and D4 hazards.
class DeclarativeExtractorTest < Minitest::Test
  include Hallmark::Guard::DSL

  BUGGY = File.join(HallmarkTestHelpers::FIXTURES, "apps", "declarative_buggy")
  FIXED = File.join(HallmarkTestHelpers::FIXTURES, "apps", "declarative_fixed")
  FLAGS = %i[project_public public_builds archived].freeze

  def mapping(ip_term: true)
    mapping = Hallmark::Mapping.new
    mapping.instance_eval do
      platform_role :admin
      tenant "Project", membership: "ProjectMember", roles: :access_level
      public_when = flag(:project_public) & flag(:public_builds)
      resource "Schedule", tenant: :project, flags: FLAGS, public_when: public_when
      resource "Project", tenant: :itself, flags: FLAGS, public_when: public_when
      %w[Schedule Project].each do |name|
        grant :reporter, :read, name
        grant :guest, :read, name, when: flag(:public_builds)
      end
      rule "SchedulePolicy", :read_schedule, op: :read
      rule "ProjectPolicy", :read_schedule, op: :read
      rule "ProjectPolicy", :update_schedule, op: :write
      rule "ProjectPolicy", :star_project, op: :write
      %w[public? public_builds? archived?].zip(FLAGS).each do |reader, name|
        term "record.#{reader}", flag(name)
        term "record.project.#{reader}", flag(name)
      end
      term "guest", role(:guest, tenant: :record) | role(:reporter, tenant: :record)
      term "reporter", role(:reporter, tenant: :record)
      term "ip_restricted", Hallmark::Guard.new(:never) if ip_term
    end
    mapping
  end

  def extractor(root = BUGGY, **) = Hallmark::Extractor.new(mapping(**), root)
  def lower(policy, ability, root = BUGGY, **) = extractor(root, **).fetch(policy, ability).lower

  # Whether a guard allows when exactly `held` of its leaves hold.
  def allows?(guard, *held)
    facts = guard.leaves.to_h { |leaf| [leaf, held.include?(leaf)] }
    guard.evaluate(facts)
  end

  def reporter = role(:reporter, tenant: :record)

  # The schedule delegates to its project, whose `public_access` lets an
  # anonymous visitor read schedules even with public pipelines off.
  def test_reads_rules_and_delegates
    guard = lower("SchedulePolicy", "read_schedule")

    assert allows?(guard, flag(:project_public))
    refute allows?(guard)
    assert allows?(guard, logged_in, reporter)
    assert_equal "Schedule", extractor.fetch("SchedulePolicy", "read_schedule").resource
  end

  # `prevent(*read_update(:schedule))` is read through the class methods.
  def test_reads_ability_lists_built_by_helpers
    guard = lower("ProjectPolicy", "read_schedule")

    refute allows?(guard, logged_in, reporter, flag(:archived))
    assert allows?(guard, logged_in, reporter)
  end

  def test_the_fixed_rule_needs_public_pipelines
    guard = lower("SchedulePolicy", "read_schedule", FIXED)

    refute allows?(guard, flag(:project_public))
    assert allows?(guard, flag(:project_public), flag(:public_builds))
  end

  # The EE module's `prevent_all` applies. With its condition unmapped it
  # may prevent anyone it does not exempt, so only admins are certainly
  # allowed.
  def test_reads_prepended_ee_modules
    unmapped = lower("ProjectPolicy", "read_schedule", ip_term: false)

    refute allows?(unmapped, logged_in, reporter)
    assert allows?(unmapped, logged_in, role(:admin))
    assert allows?(lower("ProjectPolicy", "read_schedule"), logged_in, reporter)
  end

  # D4: `guest && reporter` is `reporter`, as Ruby evaluates it.
  def test_ruby_boolean_operators_are_read_as_ruby_evaluates_them
    found = extractor
    guard = found.fetch("ProjectPolicy", "update_schedule").lower

    assert allows?(guard, logged_in, reporter)
    refute allows?(guard, logged_in, role(:guest, tenant: :record))
    assert_includes found.lints.map(&:kind), "D4"
  end

  def test_flags_a_condition_cached_at_the_wrong_scope
    found = extractor
    found.fetch("ProjectPolicy", "star_project")
    lint = found.lints.find { |each| each.kind == "D3" }

    assert_equal "app/policies/project_policy.rb:14", lint.location
    assert_match(/`pinned` is cached with scope: :user but reads the subject/, lint.message)
  end

  def test_lists_abilities_from_the_mapping
    keys = extractor.rules.map(&:key)

    assert_equal %w[ProjectPolicy#read_schedule ProjectPolicy#star_project ProjectPolicy#update_schedule
                    SchedulePolicy#read_schedule], keys.sort
  end

  def test_models_flags_and_conditional_grants
    analysis = Hallmark::Analysis.new("Flags", mapping: mapping)
    analysis.add_exposure(action: "SchedulesController#show", op: :read, resource: "Schedule",
                          guard: flag(:project_public))
    source = Hallmark::ModelBuilder.new(analysis.validate!).source

    assert_includes source, "one sig RecordFlags { flag_archived: set Resource, flag_project_public: set Resource, " \
                            "flag_public_builds: set Resource }"
    assert_includes source, "all r: Schedule | r in Public iff (r in RecordFlags.flag_project_public and " \
                            "r in RecordFlags.flag_public_builds)"
    assert_includes source, ".res = { r: Schedule | r in RecordFlags.flag_public_builds }"
  end

  def test_rejects_flags_a_resource_does_not_declare
    assert_raises(Hallmark::ConfigurationError) do
      Hallmark::Mapping.new.resource("Post", flags: %i[a], public_when: flag(:b))
    end
    assert_raises(Hallmark::ConfigurationError) { Hallmark::Mapping.new.grant(:guest, :read, "Post", when: logged_in) }
  end

  # Grape endpoints, named as the Grape collector names them, with the
  # abilities they check in their block and in helpers, with or without
  # arguments (`project` calls `find_project!(id)`, whose ability comes from
  # `read_project_ability`).
  def test_reads_grape_endpoints
    endpoints = Hallmark::Extractor::GrapeEndpoints.new(mapping, BUGGY).endpoints
    checks = endpoints.to_h do |endpoint|
      [endpoint.name, endpoint.authorizations.map { |found| [found.policy, found.rule] }]
    end

    read_project = %w[ProjectPolicy read_project]

    assert_equal({ "GET /projects/:id/schedules" => [%w[ProjectPolicy read_schedule], read_project],
                   "GET /projects/:id/schedules/:schedule_id" => [read_project, %w[SchedulePolicy read_schedule]],
                   "POST /projects/:id/schedules" => [%w[ProjectPolicy create_schedule], read_project],
                   "GET /projects/:id/status" => [] }, checks)
  end

  # Endpoints no test reached become exposures from the rules they check;
  # one with no check is listed, not failed.
  def test_unreached_grape_endpoints_are_checked_from_code
    Hallmark.configuration.root = BUGGY
    inference = Hallmark::Analysis.build("Grape", mapping: mapping) { stamps Hallmark::StampSet.new }.inference

    assert_equal ["GET /projects/:id/schedules", "GET /projects/:id/schedules/:schedule_id"],
                 inference.exposures.map(&:action).sort
    assert_includes inference.coverage.routes_unchecked, "GET /projects/:id/status"
    assert_includes inference.coverage.routes_unresolved, "POST /projects/:id/schedules"
  end

  # The detect-then-fix pair, from code alone.
  def test_finds_the_bug_and_not_the_fix
    solver = require_solver!
    results = [BUGGY, FIXED].map do |root|
      check = Hallmark::RuleCheck.new(mapping, Hallmark::StampSet.new, extractor: extractor(root))
      check.check("SchedulePolicy", ["read_schedule"], solver: solver).fetch(0)
    end

    assert_equal %i[counterexample none], results.map(&:verdict)
    assert_match(/an anonymous visitor can read a Schedule .* with project_public and without public_builds/,
                 results.fetch(0).finding.message)
  end
end
