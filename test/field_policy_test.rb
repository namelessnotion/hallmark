# frozen_string_literal: true

require "test_helper"
require_relative "support/fixture_solver"

# Field policies (phase 3 step 4, threats 4 and 14 G1): who may read one
# field of a record, ANDed into the check of every read of that field.
class FieldPolicyTest < Minitest::Test
  include Hallmark::Guard::DSL

  def accounts(&)
    Hallmark::Analysis.build("Accounts") do
      map do
        tenant "Organization", membership: "Membership"
        platform_role :support
        resource "User", tenant: :organization, owner: :itself, flags: %i[verified]
        grant :member, :read, "User"
        grant :admin, :read, "User"
      end
      instance_eval(&)
    end
  end

  def source(analysis) = Hallmark::ModelBuilder.new(analysis).source

  def test_a_field_exposure_is_named_after_its_field
    analysis = accounts do
      map { field_policy "User", :email, owner | role(:admin, tenant: :record) }
      reads "UsersController#show", "User", field: :email, guard: role(:member, tenant: :record)
    end
    exposure = analysis.exposures.fetch(0)

    assert_equal "email", exposure.field
    assert_equal "safe_UsersController_show_read_User_email", exposure.check_name
    assert_equal "User.email", exposure.target
    assert_equal "UsersController#show (read User.email, guard: role(:member, tenant: :record))", exposure.to_s
  end

  def test_the_field_and_the_whole_record_are_separate_checks
    analysis = accounts do
      reads "UsersController#show", "User", guard: role(:member, tenant: :record)
      reads "UsersController#show", "User", field: :email, guard: role(:member, tenant: :record)
    end

    assert_equal %w[safe_UsersController_show_read_User safe_UsersController_show_read_User_email],
                 analysis.exposures.map(&:check_name)
  end

  def test_the_check_ands_the_field_policy_into_the_records_read
    text = source(accounts do
      map { field_policy "User", :email, owner | role(:admin, tenant: :record) }
      reads "UsersController#show", "User", field: :email, guard: role(:member, tenant: :record)
    end)

    assert_includes text, "-- UsersController#show: read User.email, guard: role(:member, tenant: :record)\n" \
                          "-- field policy: User.email readable where (owner | role(:admin, tenant: :record))"
    assert_includes text, "implies (allowed[p, Read, r] and (r.owner = p or Role_admin in rolesIn[p, r.tenant]))"
  end

  def test_a_field_with_no_policy_is_checked_as_the_record_and_listed
    analysis = accounts do
      reads "UsersController#show", "User", field: :phone, guard: role(:member, tenant: :record)
    end
    report = analysis.run(solver: FixtureSolver.new)

    assert_includes source(analysis), "implies allowed[p, Read, r]\n"
    assert_equal ["UsersController#show"], analysis.fields_without_policy.map(&:action)
    assert_includes report.to_s, "Fields with no field policy (checked as readable as their record; " \
                                 "declare `field_policy` to narrow):\n  UsersController#show (read User.phone)"
    assert_includes report.to_s, "ok    UsersController#show (read User.phone)"
  end

  def test_fields_exist_only_on_reads
    error = assert_raises(Hallmark::ConfigurationError) do
      accounts { writes "UsersController#update", "User", field: :email, guard: owner }
    end
    assert_match(/fields exist only on reads/, error.message)
  end

  def test_a_field_policy_is_validated_like_a_guard
    {
      proc { field_policy "Invoice", :total, owner } => /resource Invoice is not mapped/,
      proc { field_policy "User", :email, owner | Hallmark::Guard.new(:opaque, "x.y?") } => /cannot model: opaque/,
      proc { field_policy "User", :email, flag(:archived) } => /does not declare: archived/,
      proc { field_policy "User", :email, role(:admin) } => /checks admin outside any tenant/,
      proc { field_policy "User", :email, permitted } => /mapped without `permits:`/,
      proc { field_policy "User", :email, outside_tenants } => /without `tenant_optional:`/
    }.each do |declaration, message|
      error = assert_raises(Hallmark::ConfigurationError) do
        accounts do
          map(&declaration)
          reads "UsersController#show", "User", field: :email, guard: owner
        end
      end
      assert_match message, error.message
    end
  end

  def test_tenant_terms_need_a_tenant
    error = assert_raises(Hallmark::ConfigurationError) do
      Hallmark::Analysis.build("Blog") do
        map do
          resource "Post", owner: :author
          field_policy "Post", :draft, role(:editor, tenant: :record)
        end
      end
    end
    assert_match(/field policy for Post.draft reads tenants/, error.message)
  end

  def test_a_field_policy_is_declared_once
    error = assert_raises(Hallmark::ConfigurationError) do
      accounts do
        map do
          field_policy "User", :email, owner
          field_policy "User", :email, role(:admin, tenant: :record)
        end
      end
    end
    assert_match(/field policy User.email is mapped twice/, error.message)
    assert_raises(Hallmark::ConfigurationError) { accounts { map { field_policy "User", :email, "owner" } } }
  end

  # An analysis's map block adds to a copy, never to the configured mapping.
  def test_field_policies_are_copied_with_the_mapping
    mapping = Hallmark::Mapping.new
    mapping.resource "User", owner: :itself
    copy = mapping.dup
    copy.field_policy "User", :email, owner

    assert_empty mapping.field_policies
    assert_equal ["User.email"], copy.field_policies.keys
  end

  def test_the_digest_changes_with_the_field_and_its_policy
    digest = lambda do |field, policy = nil|
      analysis = accounts do
        map { field_policy "User", :email, policy } if policy
        reads "UsersController#show", "User", field: field, guard: role(:member, tenant: :record)
      end
      analysis.exposures.fetch(0).digest(analysis.mapping)
    end
    record = digest.call(nil)
    email = digest.call(:email)

    refute_equal record, email
    refute_equal email, digest.call(:phone)
    refute_equal email, digest.call(:email, owner)
    refute_equal digest.call(:email, owner), digest.call(:email, role(:admin, tenant: :record))
  end

  # The digest of an exposure with no field and no restriction is the one
  # step 3 wrote, so an older baseline still matches.
  def test_the_digest_of_a_whole_record_read_is_unchanged
    analysis = accounts { reads "UsersController#show", "User", guard: role(:member, tenant: :record) }
    exposure = analysis.exposures.fetch(0)
    before = Digest::SHA256.hexdigest(JSON.generate([exposure.check_name, "read", "User", exposure.guard.to_s, [],
                                                     nil]))

    assert_equal before, exposure.digest(analysis.mapping)
  end

  def test_a_member_reading_an_email_only_the_owner_may_read
    solver = require_solver!
    report = accounts do
      map { field_policy "User", :email, owner | role(:admin, tenant: :record) }
      reads "UsersController#show", "User", field: :email, guard: role(:member, tenant: :record)
      reads "UsersController#contact", "User", field: :email, guard: role(:admin, tenant: :record)
    end.run(solver: solver)

    assert_equal ["UsersController#contact"], report.verified.map(&:action)
    finding = report.findings.fetch(0)
    assert_predicate finding, :field_policy_broken?
    assert_nil finding.restriction
    assert_match(/can read the email of a User owned by User\$\d/, finding.message)
    assert finding.message.end_with?(", which its field policy allows only where " \
                                     "(owner | role(:admin, tenant: :record))")
    assert_match(/check the code that decides whether User.email is shown/, finding.hint)
  end

  # When the witness breaks neither the field policy (as far as it says)
  # nor a restriction, the report lists what else the check asked for.
  def test_an_unsure_finding_lists_what_was_intended
    analysis = Hallmark::Analysis.build("Store") do
      map do
        tenant "User", membership: "TeamMembership", self: :owner
        current_tenant :seller
        resource "Link", tenant: :user, public_if: :published?
        grant :admin, :read, "Link"
        field_policy "Link", :price, public_record
      end
      reads "LinksController#show", "Link", field: :price, guard: role(:admin, tenant: :current)
    end
    report = analysis.run(solver: FixtureSolver.new("safe_LinksController_show_read_Link_price" => :counterexample))
    finding = report.findings.fetch(0)

    refute_predicate finding, :field_policy_broken?
    assert_equal "field policy for Link.price: public_record", finding.intended
    assert_includes report.to_s, "      intended: field policy for Link.price: public_record\n"
  end
end
