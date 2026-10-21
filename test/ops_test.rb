# frozen_string_literal: true

require "test_helper"

# A rule's op (`Ops`): the mapping, the rule's name, then the verbs of the
# routes that reach it, recorded or read from the board fixture's code. No
# Java.
class OpsTest < Minitest::Test
  ROOT = File.join(HallmarkTestHelpers::FIXTURES, "apps", "board")

  def named(rule, mapping = Hallmark::Mapping.new) = Hallmark::Ops.named(mapping, "P", rule)

  def test_pages_that_only_show_something_read_by_name
    reads = %w[index? show? new? edit? preview? paged? statistics? stats? export? index_collections? show_in_v4?
               new_payout? edit_balance? export_donors? followers_count? ledger_stats? card_overview?
               categories_chart?]
    writes = %w[create? update? destroy? cancel? toggle_pinned? collections? add_collections? publish? reset?]

    assert_equal(reads, reads.select { |rule| named(rule) == :read })
    assert_equal(writes, writes.select { |rule| named(rule) == :write })
    assert_nil named("read_project")
  end

  def test_the_mapping_overrides_the_name
    mapping = Hallmark::Mapping.new
    mapping.rule "P", :show?, op: :write
    mapping.rule "P", :read_project, op: :read

    assert_equal :write, named("show?", mapping)
    assert_equal :read, named("read_project", mapping)
  end

  def code_ops(mapping = Hallmark::Mapping.new)
    extractor = Hallmark::Extractor.new(mapping, ROOT)
    Hallmark::Ops.new(mapping, routes: extractor.routes, controllers: extractor.controllers)
  end

  # The board's controller loads `@event` through a helper, so its
  # authorize calls name EventPolicy by the variable.
  def test_a_rule_only_get_requests_reach_reads
    ops = code_ops

    assert_equal :read, ops.fetch("EventPolicy", "ledger?")
    assert_equal "read: only GET requests reach it (EventsController#ledger)", ops.basis("EventPolicy", "ledger?")
    assert_nil ops.basis("EventPolicy", "show?")
  end

  # A POST anywhere, a rule no route reaches, and a declared op all keep
  # the rule a write; a verb never makes a read-named rule write.
  def test_any_other_verb_or_no_route_keeps_a_write
    mapping = Hallmark::Mapping.new
    mapping.rule "EventPolicy", :ledger?, op: :write
    ops = code_ops(mapping)

    writes = %w[statement? toggle_pinned? update? unrouted? ledger?]

    assert_equal(%i[write] * writes.size, writes.map { |rule| ops.fetch("EventPolicy", rule) })
    assert_nil ops.basis("EventPolicy", "ledger?")
    assert_equal :read, ops.fetch("EventPolicy", "new_payout?")
  end

  def stamp(rule, entry_point)
    Hallmark::Stamp.new(policy: "LinkPolicy", rule: rule, resource: "Link", decision: "allow", enforced: true,
                        entry_point: entry_point)
  end

  # Recorded routes, tied to rules by the stamps' entry points: a GET
  # reads, a route open to any verb ("") or to GET and POST does not.
  def test_reads_recorded_routes_through_stamps
    routes = [Hallmark::Route.new(entry_point: "LinksController#stats", verb: "GET", path: "/l/:id/stats"),
              Hallmark::Route.new(entry_point: "LinksController#ping", verb: "GET|POST", path: "/l/:id/ping"),
              Hallmark::Route.new(entry_point: "LinksController#hook", verb: "", path: "/l/:id/hook")]
    stamps = [stamp("sales?", "LinksController#stats"), stamp("ping?", "LinksController#ping"),
              stamp("hook?", "LinksController#hook"), stamp("sales_report?", "LinksController#stats"),
              stamp("sales_report?", "LinksController#ping")]
    ops = Hallmark::Ops.new(Hallmark::Mapping.new, stamps: stamps, routes: routes)

    ops_of = %w[sales? ping? hook? sales_report?].to_h { |rule| [rule, ops.fetch("LinkPolicy", rule)] }

    assert_equal({ "sales?" => :read, "ping?" => :write, "hook?" => :write, "sales_report?" => :write }, ops_of)
  end

  # An analysis reads the routes from code when none were recorded, and
  # says why a rule reads.
  def test_inference_takes_ops_from_code_routes
    mapping = Hallmark::Mapping.new
    mapping.resource "Event"
    inference = Hallmark::Inference.new(mapping, Hallmark::StampSet.new,
                                        extractor: Hallmark::Extractor.new(mapping, ROOT))
    units = inference.units.to_h { |unit| [unit.rule, unit] }

    assert_equal :read, units.fetch("ledger?").op
    assert_includes units.fetch("ledger?").basis, "read: only GET requests reach it (EventsController#ledger)"
    assert_equal :write, units.fetch("archive?").op
  end

  # Grape endpoints are named by their verb.
  def test_reads_a_grape_endpoints_verb
    stamps = [Hallmark::Stamp.new(policy: "ProjectPolicy", rule: "pipelines?", resource: "Project", decision: "allow",
                                  enforced: true, entry_point: "GET /projects/:id/pipelines")]

    assert_equal :read, Hallmark::Ops.new(Hallmark::Mapping.new, stamps: stamps).fetch("ProjectPolicy", "pipelines?")
  end
end
