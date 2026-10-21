# frozen_string_literal: true

require "test_helper"
require_relative "support/fixture_solver"

# Restrictions (phase 3 step 4, threat 11): what must never happen even
# when a catalog pattern allows it, ANDed as a negation into the check of
# every exposure a restriction covers.
class RestrictionTest < Minitest::Test
  include Hallmark::Guard::DSL

  CARDS = "admins never read card numbers"

  def billing(&)
    Hallmark::Analysis.build("Billing") do
      map do
        tenant "Organization", membership: "Membership"
        platform_role :support
        resource "PaymentMethod", tenant: :organization, owner: :user, flags: %i[archived]
        grant :admin, :read, "PaymentMethod"
        grant :admin, :write, "PaymentMethod"
        restrict CARDS do
          deny role: :admin, op: :read, resource: "PaymentMethod", fields: %i[number cvc]
        end
      end
      instance_eval(&)
    end
  end

  def source(analysis) = Hallmark::ModelBuilder.new(analysis).source

  def test_a_restriction_holds_its_denials
    restriction = billing { nil }.mapping.restrictions.fetch(CARDS)
    denial = restriction.denials.fetch(0)

    assert_equal "admin", denial.role
    assert_equal [:read], denial.ops
    assert_equal "PaymentMethod", denial.resource
    assert_equal %w[number cvc], denial.fields
    assert_equal 'deny role: :admin, op: :read, resource: "PaymentMethod", fields: %i[number cvc]', denial.to_s
  end

  def test_a_covering_restriction_adds_its_negation
    text = source(billing do
      reads "PaymentMethodsController#show", "PaymentMethod", field: :number, guard: role(:admin, tenant: :record)
    end)

    assert_includes text, "-- restriction \"#{CARDS}\": deny role: :admin, op: :read, resource: \"PaymentMethod\", " \
                          "fields: %i[number cvc]"
    assert_includes text, "implies (allowed[p, Read, r] and (not (Role_admin in rolesFor[p, r])))"
  end

  # `fields:` covers reads of those fields only, never the whole record.
  def test_fields_scope_what_a_restriction_covers
    analysis = billing do
      reads "PaymentMethodsController#index", "PaymentMethod", guard: role(:admin, tenant: :record)
      reads "PaymentMethodsController#show", "PaymentMethod", field: :brand, guard: role(:admin, tenant: :record)
    end

    analysis.exposures.each { |exposure| assert_empty analysis.mapping.restrictions_for(exposure) }
    refute_includes source(analysis), "not ("
  end

  # Without `fields:` a restriction covers every exposure of the resource
  # and op, field or not; a platform role counts anywhere, and `when:`
  # limits the records.
  def test_a_whole_record_restriction_covers_fields_too
    text = source(billing do
      map do
        restrict "support never touches archived cards" do
          deny role: :support, op: %i[read write], resource: "PaymentMethod", when: flag(:archived)
        end
      end
      reads "PaymentMethodsController#index", "PaymentMethod", guard: role(:support)
      reads "PaymentMethodsController#show", "PaymentMethod", field: :number, guard: role(:support)
      writes "PaymentMethodsController#update", "PaymentMethod", guard: role(:support)
    end)
    support = "(not ((Role_support in effective[p] and r in RecordFlags.flag_archived)))"

    assert_equal 3, text.scan(support).size
    assert_includes text, "(allowed[p, Read, r] and (not (Role_admin in rolesFor[p, r])) and #{support})"
    assert_includes text, "-- restriction \"support never touches archived cards\": deny role: :support, " \
                          "op: %i[read write], resource: \"PaymentMethod\", when: flag(:archived)"
  end

  # The documented order: the public action ORs into the catalog's
  # `allowed`, then the field policy and each restriction AND in.
  def test_public_actions_field_policies_and_restrictions_compose_in_order
    analysis = billing do
      map do
        field_policy "PaymentMethod", :number, owner
        public_action "PaymentMethodPolicy", :show?, audience: :signed_in
      end
    end
    analysis.add_exposure(action: "PaymentMethodsController#show", op: :read, resource: "PaymentMethod",
                          guard: logged_in, rules: ["PaymentMethodPolicy#show?"], field: :number)
    text = source(analysis.validate!)

    assert_includes text, "implies ((allowed[p, Read, r] or publicAction[p, User]) and r.owner = p and " \
                          "(not (Role_admin in rolesFor[p, r])))"
    assert_includes text, "-- public action for signed-in users\n-- field policy: PaymentMethod.number readable " \
                          "where owner\n-- restriction \"#{CARDS}\""
  end

  def test_restriction_roles_are_declared_in_the_model
    analysis = Hallmark::Analysis.build("Shop") do
      map do
        resource "Order", owner: :buyer
        grant :clerk, :read, "Order"
        restrict("clerks never edit orders") { deny role: :clerk, op: :write, resource: "Order" }
      end
      writes "OrdersController#update", "Order", guard: owner
    end

    assert_includes source(analysis), "one sig Role_clerk extends Role {}"
  end

  def test_a_restriction_is_validated
    {
      proc { restrict("x") { deny role: :auditor, op: :read, resource: "PaymentMethod" } } =>
        /denies role auditor, which the map block never declares/,
      proc { restrict("x") { deny role: :admin, op: :read, resource: "Invoice" } } => /resource Invoice is not mapped/,
      proc { restrict("x") { deny role: :admin, op: :read, resource: "PaymentMethod", when: flag(:expired) } } =>
        /reads flags PaymentMethod does not declare: expired/,
      proc { restrict("x") { deny role: :admin, op: :delete, resource: "PaymentMethod" } } =>
        /`op:` must be :read, :write or both/,
      proc { restrict("x") { deny role: :admin, op: :write, resource: "PaymentMethod", fields: %i[number] } } =>
        /`fields:` needs `op: :read`/,
      proc { restrict("x") { deny role: :admin, op: :read, resource: "PaymentMethod", when: owner } } =>
        /`when:` must be a guard over flags/,
      proc { restrict("x") { nil } } => /denies nothing/,
      proc { restrict("x") } => /needs a block/,
      proc { restrict(CARDS) { deny role: :admin, op: :read, resource: "PaymentMethod" } } => /declared twice/
    }.each do |declaration, message|
      error = assert_raises(Hallmark::ConfigurationError) { billing { map(&declaration) } }
      assert_match message, error.message
    end
  end

  # A role is declared by a grant, a platform role, `self:` or a field policy.
  def test_roles_declared_by_self_and_field_policies_may_be_restricted
    analysis = Hallmark::Analysis.build("Store") do
      map do
        tenant "User", membership: "TeamMembership", self: :owner
        resource "Link", tenant: :user
        field_policy "Link", :revenue, role(:accountant, tenant: :record)
        restrict("owners never read payouts") { deny role: :owner, op: :read, resource: "Link", fields: %i[payout] }
        restrict("accountants never write") { deny role: :accountant, op: :write, resource: "Link" }
      end
    end

    assert_equal 2, analysis.mapping.restrictions.size
  end

  def test_configuration_restrict_adds_to_the_configured_mapping
    Hallmark.configure do |c|
      c.map { resource "PaymentMethod", owner: :user }
      c.map { grant :admin, :read, "PaymentMethod" }
      c.restrict(CARDS) { deny role: :admin, op: :read, resource: "PaymentMethod", fields: %i[number] }
    end
    analysis = Hallmark.analyze("Copy") { nil }
    analysis.mapping.restrict("another") { deny role: :admin, op: :write, resource: "PaymentMethod" }

    assert_equal [CARDS], Hallmark.configuration.mapping.restrictions.keys
    assert_equal [CARDS, "another"], analysis.mapping.restrictions.keys
  end

  # `hallmark watch` re-checks an exposure whose digest changed, so a
  # covering restriction must change it; one that does not cover must not.
  def test_the_digest_changes_with_a_covering_restriction
    digest = lambda do |denied = nil, ops = nil|
      analysis = billing do
        map { restrict("extra") { deny role: denied, op: ops, resource: "PaymentMethod" } } if denied
        reads "PaymentMethodsController#index", "PaymentMethod", guard: role(:admin, tenant: :record)
      end
      analysis.exposures.fetch(0).digest(analysis.mapping)
    end
    plain = digest.call
    covered = digest.call(:admin, :read)

    assert_equal plain, digest.call(:admin, :write)
    refute_equal plain, covered
    refute_equal covered, digest.call(:support, :read)
  end

  def test_an_admin_reading_a_card_number_breaks_the_restriction
    solver = require_solver!
    report = billing do
      reads "PaymentMethodsController#show", "PaymentMethod", field: :number, guard: role(:admin, tenant: :record)
      reads "PaymentMethodsController#index", "PaymentMethod", guard: role(:admin, tenant: :record)
    end.run(solver: solver)

    assert_equal ["PaymentMethodsController#index"], report.verified.map(&:action)
    finding = report.findings.fetch(0)
    assert_equal CARDS, finding.restriction&.name
    assert_match(/can read the number of a PaymentMethod .*where they hold roles (\w+, )*admin/, finding.message)
    assert finding.message.end_with?(", which the restriction \"#{CARDS}\" forbids")
    assert_equal "exclude holders of :admin in the code, or narrow the restriction \"#{CARDS}\" if this is intended",
                 finding.hint
    assert_includes report.to_s, "FAIL  PaymentMethodsController#show (read PaymentMethod.number)"
  end

  def test_the_sidecar_gives_the_same_verdicts
    require_solver!
    sidecar = require_sidecar!
    analysis = billing do
      reads "PaymentMethodsController#show", "PaymentMethod", field: :number, guard: role(:admin, tenant: :record)
      writes "PaymentMethodsController#update", "PaymentMethod", guard: role(:admin, tenant: :record)
    end
    report = analysis.run(solver: sidecar)

    assert_equal(["PaymentMethodsController#show"], report.findings.map { |finding| finding.exposure.action })
    assert_equal ["PaymentMethodsController#update"], report.verified.map(&:action)
    assert_equal CARDS, report.findings.fetch(0).restriction&.name
  ensure
    sidecar&.close
  end
end
