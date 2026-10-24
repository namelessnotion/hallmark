# frozen_string_literal: true

require "test_helper"

# The REST shop example end to end (phase 3 step 8): its field policy and
# restriction findings read from serializers, controllers, policies and
# routes alone, explained from the captured run in test/fixtures/rest_shop
# (no Java), then on the real backends, and none for the fixed app; and a
# Grape entity's field finding on the DeclarativePolicy fixture.
class RestShopTest < Minitest::Test
  include Hallmark::Guard::DSL

  def report
    analysis = load_example("rest_shop/hallmark.rb")
    Hallmark::Report.new(analysis, Hallmark::Receipt.load(File.join(FIXTURES, "rest_shop")))
  end

  def test_reports_the_field_policy_and_the_restriction
    found = report

    assert_equal(%w[safe_Admin_LinksController_show_read_Link_buyer_emails safe_LinksController_show_read_Link_revenue],
                 found.findings.map { _1.exposure.check_name })
    assert_equal %w[safe_Admin_LinksController_show_read_Link safe_LinksController_show_read_Link],
                 found.verified.map(&:check_name)
    assert_equal 1, found.exit_code
  end

  def test_explains_each_finding_at_its_serializer
    findings = report.findings.to_h { |finding| [finding.exposure.field, finding] }
    revenue = findings.fetch("revenue")

    assert_predicate revenue, :field_policy_broken?
    assert_equal ["marketing"], revenue.current_tenant&.roles
    assert_includes revenue.hint, "narrow the condition on revenue in LinkSerializer#revenue " \
                                  "(app/serializers/link_serializer.rb:7)"
    assert_equal "staff never see buyers", findings.fetch("buyer_emails").restriction&.name
  end

  def test_report_lines
    text = report.to_s

    assert_includes text, "FAIL  LinksController#show (read Link.revenue, shown by LinkSerializer#revenue " \
                          "(app/serializers/link_serializer.rb:7))"
    assert_includes text, "shown by LinkSerializer (app/serializers/link_serializer.rb:7) where"
    assert_includes text, "2 counterexamples in 4 checks."
  end

  def test_buggy_and_fixed_on_the_cli
    solver = require_solver!

    assert_equal [2, 0], verdicts(solver)
  end

  def test_buggy_and_fixed_on_the_sidecar
    require_solver!
    sidecar = require_sidecar!

    assert_equal [2, 0], verdicts(sidecar)
  ensure
    sidecar&.close
  end

  # A Grape entity's conditional field: ScheduleDetails shows variables
  # wherever the schedule's own ability holds, which reads public
  # projects as readable by anyone, wider than the field policy.
  def test_a_grape_entity_field_finding
    solver = require_solver!
    root = File.join(FIXTURES, "apps", "declarative_buggy")
    Hallmark.configuration.root = root
    mapping = DeclarativeMapping.build
    mapping.field_policy "Schedule", :variables, role(:reporter, tenant: :record)
    analysis = Hallmark::Analysis.build("Grape fields", mapping: mapping) { from_code root }
    report = analysis.run(solver: solver)
    finding = report.findings.find { |each| each.exposure.field == "variables" }

    refute_nil finding
    assert_equal "GET /projects/:id/schedules/:schedule_id", finding.exposure.action
    assert_match(%r{\AAPI::Entities::ScheduleDetails#variables \(lib/api/entities/schedule_details\.rb:9\)\z},
                 finding.exposure.shown_by)
  end

  private

  def verdicts(solver)
    %w[hallmark.rb hallmark_fixed.rb].map do |file|
      load_example("rest_shop/#{file}").run(solver: solver).findings.size
    end
  end

  # The DeclarativePolicy fixture's mapping (as DeclarativeExtractorTest's).
  module DeclarativeMapping
    extend Hallmark::Guard::DSL

    FLAGS = %i[project_public public_builds archived].freeze

    def self.build
      mapping = Hallmark::Mapping.new
      flags = FLAGS
      mapping.instance_eval do
        platform_role :admin
        tenant "Project", membership: "ProjectMember", roles: :access_level
        public_when = flag(:project_public) & flag(:public_builds)
        resource "Schedule", tenant: :project, flags: flags, public_when: public_when
        resource "Project", tenant: :itself, flags: flags, public_when: public_when
        %w[Schedule Project].each do |name|
          grant :reporter, :read, name
          grant :guest, :read, name, when: flag(:public_builds)
        end
        rule "SchedulePolicy", :read_schedule, op: :read
        rule "ProjectPolicy", :read_schedule, op: :read
        rule "ProjectPolicy", :read_project, op: :read
        %w[public? public_builds? archived?].zip(flags).each do |reader, name|
          term "record.#{reader}", flag(name)
          term "record.project.#{reader}", flag(name)
        end
        term "guest", role(:guest, tenant: :record) | role(:reporter, tenant: :record)
        term "reporter", role(:reporter, tenant: :record)
        term "ip_restricted", Hallmark::Guard.new(:never)
      end
      mapping
    end
  end
end
