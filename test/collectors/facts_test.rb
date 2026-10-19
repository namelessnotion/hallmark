# frozen_string_literal: true

require "test_helper"

# Collectors::Facts read directly, for record shapes the shop fixtures lack.
class FactsTest < Minitest::Test
  module Forum
    User = Struct.new(:name, :admin)
    Organization = Struct.new(:name)
    Article = Struct.new(:user, :organization)
    Policy = Struct.new(:user, :record)
  end

  def setup
    @mapping = Hallmark::Mapping.new.tap do |m|
      m.instance_eval do
        principal "FactsTest::Forum::User", roles: ->(user) { user.admin ? ["admin"] : [] }
        platform_role :admin
        tenant "FactsTest::Forum::Organization", roles_in: ->(_user, org) { org.name == "acme" ? ["org_admin"] : [] }
        resource "FactsTest::Forum::Article", owner: :user, tenant: :organization, tenant_optional: true
      end
    end
    @ada = Forum::User.new("ada", true)
  end

  # With no tenant, the roles that count are those held outside tenants, as
  # in the catalog's `rolesFor`, so the record roles are left unset.
  def test_a_record_without_its_optional_tenant_counts_roles_outside_tenants
    stamp = stamp_for(Forum::Article.new(@ada, nil))

    assert_equal [true, false, true, nil, nil, ["admin"]],
                 stamp.to_h.values_at(:owner, :member, :outside_tenants, :record_roles, :in_current_tenant, :roles)
  end

  def test_a_record_in_its_optional_tenant_counts_roles_there
    stamp = stamp_for(Forum::Article.new(@ada, Forum::Organization.new("acme")))

    assert_equal [true, false, ["org_admin"]], stamp.to_h.values_at(:member, :outside_tenants, :record_roles)
  end

  private

  def stamp_for(article)
    Hallmark::Collectors::Facts.new(@mapping).stamp(
      policy: Forum::Policy.new(@ada, article), rule: "update?", record: article, allowed: true, raised: nil,
      enforced: true, entry_point: "ArticlesController#update"
    )
  end
end
