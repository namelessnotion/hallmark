# frozen_string_literal: true

require "test_helper"

# Exposures, guards and coverage inferred from hand-built stamps; no
# collectors and no Java.
class InferenceTest < Minitest::Test
  UPDATE = "LinksController#update"

  def stamp(rule: "update?", entry_point: UPDATE, decision: "allow", **facts)
    defaults = {
      policy: "LinkPolicy", resource: "Link", class_level: false, enforced: true, logged_in: true,
      in_current_tenant: true, roles: [], record_roles: [], current_roles: []
    }
    Hallmark::Stamp.new(**defaults, entry_point: entry_point, rule: rule, decision: decision, **facts)
  end

  def analysis(stamps, unchecked: [], &)
    Hallmark::Analysis.build("Test") do
      map do
        tenant "User", membership: "TeamMembership", self: :owner, roles_in: :team_roles_for
        platform_role :staff
        resource "Link", tenant: :user
        grant :owner, :write, "Link"
        grant :admin, :write, "Link"
        instance_eval(&) if block_given?
      end
      stamps Hallmark::StampSet.new(stamps, unchecked)
    end
  end

  def test_guard_is_the_or_of_the_allow_stamps_true_facts
    exposure = analysis([
                          stamp(current_roles: ["admin"], record_roles: ["admin"]),
                          stamp(in_current_tenant: false, current_roles: ["owner"]),
                          stamp(decision: "deny", current_roles: ["support"], record_roles: ["support"])
                        ]).exposures.fetch(0)

    assert_equal UPDATE, exposure.action
    assert_equal :write, exposure.op
    assert_equal "(logged_in & ((in_current_tenant & role(:admin, tenant: :current)) | " \
                 "role(:owner, tenant: :current)))", exposure.guard.to_s
    assert_equal "inferred from 2 allow-stamps of LinkPolicy#update?", exposure.basis
  end

  # A broader allow makes a narrower one redundant.
  def test_drops_conjunctions_another_allow_already_covers
    guard = analysis([
                       stamp(in_current_tenant: false, current_roles: ["admin"]),
                       stamp(current_roles: ["admin"], record_roles: ["admin"])
                     ]).exposures.fetch(0).guard

    assert_equal "(logged_in & role(:admin, tenant: :current))", guard.to_s
  end

  # A collaborator on another seller's link, acting for their own account.
  def test_explicit_permissions_become_a_literal_where_mapped
    collaborator = stamp(in_current_tenant: false, current_roles: ["owner"], permitted: true)
    mapped = analysis([collaborator]) { resources["Link"].permits = :collaborator_for? }
    unmapped = analysis([collaborator])

    assert_equal "((logged_in & permitted) & role(:owner, tenant: :current))", mapped.exposures.fetch(0).guard.to_s
    assert_equal "(logged_in & role(:owner, tenant: :current))", unmapped.exposures.fetch(0).guard.to_s
  end

  def test_anonymous_allows_and_platform_roles
    guard = analysis([stamp(logged_in: false, in_current_tenant: false),
                      stamp(roles: %w[staff ignored], in_current_tenant: false)])
            .exposures.fetch(0).guard

    assert_equal "no check", guard.to_s
    staff = analysis([stamp(roles: %w[staff ignored], in_current_tenant: false)]).exposures.fetch(0).guard
    # Outside tenants users hold only platform roles, so other roles are dropped.
    assert_equal "(logged_in & role(:staff))", staff.to_s
  end

  def test_a_hand_written_guard_replaces_the_inferred_one
    exposure = analysis([stamp(in_current_tenant: false, current_roles: ["admin"])]) do
      rule "LinkPolicy", :update?, guard: role(:admin, tenant: :current) & in_current_tenant
    end.exposures.fetch(0)

    assert_equal "(role(:admin, tenant: :current) & in_current_tenant)", exposure.guard.to_s
    assert_equal "hand-written for LinkPolicy#update?", exposure.basis
  end

  def test_op_convention_and_override
    mapping = Hallmark::Mapping.new
    mapping.rule "LinkPolicy", :publish?, op: :read
    mapping.rule "ProjectPolicy", :read_project, op: :read

    ops = %w[index? show? edit? update? destroy?].map { |rule| mapping.op_for("P", rule) }
    assert_equal %i[read read read write write], ops
    assert_equal :read, mapping.op_for("LinkPolicy", "publish?")
    assert_equal :read, mapping.op_for("ProjectPolicy", "read_project")
    assert_nil mapping.op_for("ProjectPolicy", "admin_project")
  end

  # An entry point that enforces two rules on one record must pass both.
  def test_entry_point_guard_is_the_and_of_its_rules
    analysis = analysis([
                          stamp(current_roles: ["admin"]),
                          stamp(rule: "publish?", current_roles: ["admin"], record_roles: ["admin"]),
                          stamp(rule: "show?", entry_point: "LinksController#show", current_roles: ["owner"])
                        ])

    assert_equal ["LinksController#show", UPDATE], analysis.exposures.map(&:action)
    update = analysis.exposures.fetch(1)
    assert_equal :and, update.guard.kind
    assert_equal "inferred from 1 allow-stamp of LinkPolicy#publish?; " \
                 "inferred from 1 allow-stamp of LinkPolicy#update?", update.basis
    assert_equal :read, analysis.exposures.fetch(0).op
  end

  def test_an_entry_point_reading_two_kinds_of_record_gets_a_check_for_each
    show = "LinksController#show"
    analysis = analysis([
                          stamp(rule: "show?", entry_point: show, current_roles: ["owner"]),
                          stamp(policy: "ShopPolicy", rule: "show?", resource: "Shop", entry_point: show,
                                current_roles: ["owner"])
                        ]) { resource "Shop", tenant: :user }

    assert_equal([[show, "Link"], [show, "Shop"]],
                 analysis.exposures.map { |exposure| [exposure.action, exposure.resource] })
    assert_equal %w[safe_LinksController_show_read_Link safe_LinksController_show_read_Shop],
                 analysis.exposures.map(&:check_name)
  end

  def test_queries_and_policy_specs_feed_guards_but_not_entry_points
    analysis = analysis([
                          stamp(entry_point: nil, enforced: false, current_roles: ["owner"]),
                          stamp(rule: "edit?", enforced: false, current_roles: ["owner"])
                        ])

    assert_empty analysis.exposures
    assert_equal ["LinkPolicy#edit?", "LinkPolicy#update?"], analysis.inference.coverage.unreached.sort
  end

  def test_rules_that_never_allowed_are_coverage_not_exposures
    analysis = analysis([stamp(decision: "deny", raised: "KeyError")])

    assert_empty analysis.exposures
    assert_equal ["LinkPolicy#update?"], analysis.inference.coverage.never_allowed
  end

  def test_class_level_unmapped_and_opless_rules_are_listed
    coverage = analysis([
                          stamp(rule: "create?", class_level: true, in_current_tenant: nil),
                          stamp(resource: "Comment"),
                          stamp(rule: "read_link")
                        ]).inference.coverage

    assert_equal ["LinkPolicy#create?"], coverage.class_level
    assert_equal ["Comment"], coverage.unmapped
    assert_equal ["LinkPolicy#read_link"], coverage.without_op
  end

  # A headless policy's stamp names the Symbol it checked; it is class-level,
  # not an unmapped resource.
  def test_a_headless_rule_is_class_level_not_unmapped
    coverage = analysis([
                          stamp(policy: "DashboardPolicy", rule: "show?", resource: "dashboard", class_level: true,
                                in_current_tenant: nil)
                        ]).inference.coverage

    assert_equal ["DashboardPolicy#show?"], coverage.class_level
    assert_empty coverage.unmapped
  end

  def unchecked(entry_point, status: nil, verb: nil)
    Hallmark::Unchecked.new(entry_point: entry_point, status: status, verb: verb)
  end

  def test_unchecked_entry_points_less_those_allowed
    events = [unchecked("PagesController#home"), unchecked("LinksController#export"),
              unchecked("PagesController#home", status: 200, verb: "GET")]
    inference = analysis([], unchecked: events) do
      allow_unchecked "PagesController#home"
    end.inference

    assert_equal ["LinksController#export"], inference.unchecked
    assert_empty inference.coverage.redirected
  end

  # Only a GET or HEAD redirect at an entry point with a stamp is excused;
  # the rest fail, sorted, once per entry point.
  def test_redirects_before_a_check_are_coverage_only_for_reads_at_stamped_entry_points
    stamped = %w[A#show B#show C#show D#show E#show F#show G#show H#show].map { |name| stamp(entry_point: name) }
    events = [
      unchecked("H#show", status: 302, verb: "GET"), unchecked("H#show", status: 302, verb: "GET"),
      unchecked("A#show", status: 303, verb: "HEAD"),
      unchecked("B#show", status: 302, verb: "POST"),   # a write that redirects
      unchecked("C#show", status: 304, verb: "GET"),    # not modified
      unchecked("D#show", status: 204, verb: "GET"),    # empty 2xx
      unchecked("E#show"),                              # written before Oct 17, 2026
      unchecked("F#show", status: 307, verb: "GET"), unchecked("F#show", status: 200, verb: "GET"),
      unchecked("Z#show", status: 302, verb: "GET")     # never reached a rule
    ]
    inference = analysis(stamped, unchecked: events).inference

    assert_equal %w[B#show C#show D#show E#show F#show Z#show], inference.unchecked
    assert_equal %w[A#show H#show], inference.coverage.redirected
  end

  # Articles live in an organization or in none (`tenant_optional:`), with
  # no current tenant.
  def article(decision: "allow", **facts)
    stamp(policy: "ArticlePolicy", resource: "Article", entry_point: "ArticlesController#update",
          decision: decision, in_current_tenant: nil, current_roles: nil, owner: true, member: true,
          outside_tenants: false, **facts)
  end

  def articles(stamps)
    Hallmark::Analysis.build("Test") do
      map do
        tenant "Organization", membership: "OrganizationMembership"
        resource "Article", owner: :user, tenant: :organization, tenant_optional: true
      end
      stamps Hallmark::StampSet.new(stamps)
    end
  end

  PERSONAL = { outside_tenants: true, member: false, record_roles: nil }.freeze

  # An owner's allow on a personal article does not stand for articles in an
  # organization: there the owner was also an organization admin.
  def test_records_outside_tenants_infer_outside_tenants
    exposure = articles([article(**PERSONAL), article(record_roles: ["admin"])]).exposures.fetch(0)

    assert_equal "((logged_in & owner) & (outside_tenants | role(:admin, tenant: :record)))", exposure.guard.to_s
  end

  # Stamps written before `outside_tenants` existed leave it unset.
  def test_stamps_without_outside_tenants_read_a_missing_tenant_from_record_roles
    old = article(**PERSONAL, outside_tenants: nil)
    exposure = articles([old, article(record_roles: ["admin"])]).exposures.fetch(0)

    assert_equal "((logged_in & owner) & (outside_tenants | role(:admin, tenant: :record)))", exposure.guard.to_s
  end

  def test_an_owner_allowed_in_a_tenant_without_roles_needs_no_outside_tenants
    guard = articles([article(**PERSONAL), article(member: false, record_roles: [])]).exposures.fetch(0).guard

    assert_equal "(logged_in & owner)", guard.to_s
  end

  def test_records_outside_tenants_are_a_coverage_dimension
    gap = articles([article(**PERSONAL), article(decision: "deny", owner: false, record_roles: [])])
          .inference.coverage.gaps.fetch(0)

    assert_includes gap.combinations, "logged_in & owner & ~outside_tenants"
    assert_includes gap.combinations, "logged_in & ~owner & outside_tenants"
    refute(gap.combinations.any? { |line| line.include?(" outside_tenants &") })
  end

  def test_not_observed_lists_whole_regions_no_stamp_reached
    coverage = analysis([
                          stamp(current_roles: ["admin"], record_roles: ["admin"]),
                          stamp(decision: "deny", current_roles: [], record_roles: [], in_current_tenant: false)
                        ]).inference.coverage
    gap = coverage.gaps.fetch(0)

    assert_equal ["LinkPolicy#update?", 1, 1], [gap.rule, gap.allows, gap.denies]
    assert_equal "~logged_in", gap.combinations.fetch(0)
    assert_includes gap.combinations, "logged_in & in_current_tenant & record_roles=[]"
    assert_includes gap.combinations, "logged_in & in_current_tenant & record_roles=[admin] & roles=[staff]"
    assert_includes gap.combinations, "logged_in & ~in_current_tenant & record_roles=[admin]"
    refute(gap.combinations.any? do |combination|
      combination.include?("current_roles") && combination.include?(" in_current_tenant")
    end)
  end

  def test_fully_observed_rules_have_no_gap
    mapping = Hallmark::Mapping.new
    mapping.resource "Post", owner: :author
    stamps = [true, false].product([true, false]).map do |logged_in, owner|
      stamp(resource: "Post", logged_in: logged_in, owner: logged_in && owner, in_current_tenant: nil,
            record_roles: nil, current_roles: nil)
    end
    coverage = Hallmark::Coverage.new(mapping, stamps)

    assert_empty coverage.not_observed(stamps, mapping.fetch("Post"))
    assert_equal ["~logged_in"], coverage.not_observed(stamps.first(2), mapping.fetch("Post"))
    assert_equal ["logged_in & ~owner"], coverage.not_observed(stamps.values_at(0, 2, 3), mapping.fetch("Post"))
  end

  # A stamp recorded before its resource was mapped with an owner has no
  # owner fact; read as is, its allow would drop ownership from the guard.
  def test_stamps_recorded_before_the_owner_was_mapped_are_not_read
    inference = Hallmark::Analysis.build("Stale") do
      map { resource "Post", owner: :user }
      stamps Hallmark::StampSet.new([Hallmark::Stamp.new(entry_point: "PostsController#update", policy: "PostPolicy",
                                                         rule: "update?", resource: "Post", class_level: false,
                                                         enforced: true, decision: "allow", logged_in: true)])
    end.inference

    assert_empty inference.exposures
    assert_equal ["PostPolicy#update?"], inference.coverage.stale
  end
end
