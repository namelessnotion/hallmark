# frozen_string_literal: true

require "test_helper"

# The GraphQL shop example end to end: G1, G2 and G3 from the schema in
# examples/graphql_shop/app/graphql, explained from the captured run in
# test/fixtures/graphql_shop (no Java), then on the real backends, and
# none for the fixed schema.
class GraphqlShopTest < Minitest::Test
  def report
    analysis = load_example("graphql_shop/hallmark.rb")
    Hallmark::Report.new(analysis, Hallmark::Receipt.load(File.join(FIXTURES, "graphql_shop")))
  end

  def findings = report.findings.to_h { |finding| [finding.exposure.check_name, finding] }

  def test_reports_each_flaw_from_the_schema
    found = report

    assert_equal(%w[reach_Invoice reach_User reach_User_email], found.findings.map { _1.exposure.check_name })
    assert_equal %w[reach_Organization reach_Project], found.verified.map(&:check_name)
    assert_equal ["G4"], found.lints.map(&:kind)
    assert_equal 1, found.exit_code
  end

  # G2: InvoiceType checks nothing, so a member who is not an admin reads
  # invoices through a project's billing page.
  def test_explains_the_nested_path_bypass
    finding = findings.fetch("reach_Invoice")

    assert_equal "query { node(id: ...) { ... on Project { billing { invoices { ... } } } } }", finding.path
    assert_equal ["member"], finding.record_tenant&.roles
    assert_equal "Explicit permission (a grant to a role)", finding.pattern
    assert_includes finding.hint.to_s, "Types::InvoiceType.authorized? (app/graphql/types/invoice_type.rb:5)"
  end

  # G3 and G1: node(id:) fetches any user, and the email with it.
  def test_explains_the_node_lookup_and_the_field_leak
    user = findings.fetch("reach_User")
    email = findings.fetch("reach_User_email")

    assert_predicate user, :anonymous?
    assert_equal "query { node(id: ...) { ... on User { ... } } }", user.path
    assert_equal "query { node(id: ...) { ... on User { email } } }", email.path
    assert_predicate email, :field_policy_broken?
  end

  def test_report_lines_name_the_path_and_the_walk
    text = report.to_s

    assert_includes text, "FAIL  GraphQL User.email (read User.email)"
    assert_includes text, "      path: query { node(id: ...) { ... on User { email } } }"
    assert_includes text, "(GraphQL hazard)"
    assert_includes text, "3 counterexamples in 5 checks, 1 GraphQL hazard."
    assert_includes text, "    Project.billing.invoices (through Billing)"
  end

  def test_sarif_locates_checks_at_their_type_and_field
    results = JSON.parse(Hallmark::Sarif.new([report]).to_json).dig("runs", 0, "results")
    places = results.to_h do |result|
      [result.dig("message", "text")[/\A\S+ \S+/],
       result.dig("locations", 0, "physicalLocation", "artifactLocation", "uri")]
    end

    assert_equal "app/graphql/types/invoice_type.rb", places.fetch("GraphQL Invoice")
    assert_equal "app/graphql/types/user_type.rb", places.fetch("GraphQL User.email")
    assert_includes results.map { _1.fetch("ruleId") }, "hallmark/G4"
  end

  def test_finds_g1_to_g3_with_the_cli
    solver = require_solver!
    found = load_example("graphql_shop/hallmark.rb").run(solver: solver)

    assert_equal(%w[reach_Invoice reach_User reach_User_email], found.findings.map { _1.exposure.check_name })
    assert_equal "query { node(id: ...) { ... on User { email } } }", found.findings.last.path
  end

  def test_the_fixed_schema_has_no_counterexample
    solver = require_solver!
    found = load_example("graphql_shop/hallmark_fixed.rb").run(solver: solver)

    assert_predicate found, :clean?
    assert_equal 5, found.verified.size
  end

  def test_the_sidecar_explains_the_same_paths
    sidecar = require_sidecar!
    found = load_example("graphql_shop/hallmark.rb").run(solver: sidecar)

    assert_equal ["query { node(id: ...) { ... on Project { billing { invoices { ... } } } } }",
                  "query { node(id: ...) { ... on User { ... } } }",
                  "query { node(id: ...) { ... on User { email } } }"], found.findings.map(&:path)
  ensure
    sidecar&.close
  end

  # `hallmark check` on a mapping alone (stamps, no analyze block) adds the
  # schema's checks when the app has app/graphql.
  def test_stamps_add_the_schema_checks
    Hallmark.configure { |config| config.root = File.join(ROOT, "examples", "graphql_shop") }
    mapping = load_example("graphql_shop/hallmark.rb").mapping
    analysis = Hallmark::Analysis.build("from stamps", mapping: mapping) { stamps Hallmark::StampSet.new }

    assert_equal 5, analysis.exposures.grep(Hallmark::GraphqlCheck).size
    assert_same analysis.inference&.graphql, analysis.graphql
  end
end
