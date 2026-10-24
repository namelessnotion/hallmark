# frozen_string_literal: true

require "test_helper"

# A type's own field class (Extractor::GraphqlFieldClasses), on
# test/fixtures/apps/graphql_runners: runners list jobs of any project,
# and after the fix (the shape of gitlab-org/gitlab!129831) a job's field
# class checks `read_build` on the job for fields other than the open
# ones, when the runner's jobs resolver has set the permission in the
# context. `before/` is the same app without the field class.
class GraphqlFieldClassesTest < Minitest::Test
  include Hallmark::Guard::DSL

  RUNNERS = File.join(HallmarkTestHelpers::FIXTURES, "apps", "graphql_runners")
  BEFORE = File.join(RUNNERS, "before")
  JOB = "Types::Ci::JobType"

  def member = role(:member, tenant: :record) | role(:maintainer, tenant: :record)

  def analysis(root)
    load File.join(root, "hallmark.rb")
    Hallmark.analyses.last
  end

  def schema(root) = Hallmark::Extractor.new(analysis(root).mapping, root).graphql
  def guard(schema, type, name) = schema.fields(type).find { |found| found.name == name }.guard

  def test_the_field_class_checks_the_permission_the_resolver_sets_except_on_open_fields
    after = schema(RUNNERS)

    assert_equal Hallmark::Guard.new(:none), guard(after, JOB, "id")
    assert_equal Hallmark::Guard.new(:none), guard(after, JOB, "status")
    assert_equal member, guard(after, JOB, "trace")
    assert_equal member, guard(after, JOB, "project")
  end

  def test_without_the_field_class_nothing_checks_the_job
    before = schema(BEFORE)

    %w[id status trace project].each { |name| assert_equal Hallmark::Guard.new(:none), guard(before, JOB, name) }
  end

  # Types::BaseField, which every BaseObject uses, is the app's default:
  # its check reads the field's own `authorize:`, already read elsewhere.
  def test_the_default_field_class_adds_nothing
    after = schema(RUNNERS)

    assert_equal Hallmark::Guard.new(:none), guard(after, "Types::Ci::RunnerType", "description")
    assert_equal member, guard(after, "Types::ProjectType", "jobs")
  end

  def test_reads_the_literals_resolvers_put_in_the_context
    index = Hallmark::Extractor::SourceIndex.new(RUNNERS, Hallmark::Extractor::GraphqlSchema::DIRS)
    classes = Hallmark::Extractor::GraphqlFieldClasses.new(index, nil, nil, aliases: {}, cleanup: :itself.to_proc)

    assert_equal({ "job_permission" => ["read_build"] }, classes.assigned)
    assert_equal "Types::Ci::JobBaseField", classes.field_class(JOB)
    assert_equal "Types::BaseField", classes.field_class("Types::ProjectType")
  end

  def test_the_trace_is_reached_through_the_runner_before_the_fix_and_not_after
    solver = require_solver!
    before = analysis(BEFORE).run(solver: solver)
    after = analysis(RUNNERS).run(solver: solver)

    assert_equal(%w[reach_CiJob reach_CiJob_trace], before.findings.map { _1.exposure.check_name })
    assert_equal "query { runner(id: ...) { jobs { nodes { trace } } } }", before.findings.last.path
    # The fix leaves the open fields to anyone who lists the runner's jobs.
    assert_equal(%w[reach_CiJob], after.findings.map { _1.exposure.check_name })
  end
end
