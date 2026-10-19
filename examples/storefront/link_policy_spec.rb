# frozen_string_literal: true

# Storefront's LinkPolicy checked with the RSpec matchers from
# `hallmark/rspec`. The first two contexts hand-write the guards (`rule ...,
# guard:`), summarizing the policy as README.md shows it; the last two read
# them from the policy code in app/policies and fixed/app/policies
# (`let(:hallmark_root)`). In an app the guards come from its own policy code
# and the stamps the rest of the suite records, and the mapping from
# config/hallmark.rb. Here each context swaps in its own mapping with
# `let(:hallmark_mapping)`.
#
# Run: bundle exec rspec examples/storefront/link_policy_spec.rb

require "hallmark/rspec"

# The example's mapping.
module Storefront
  # The mapping from hallmark.rb, plus LinkPolicy's rules unless `written:`
  # is false. `fixed:` adds the seller check that update? lacks.
  def self.mapping(fixed: false, written: true)
    mapping = Hallmark::Mapping.new
    mapping.instance_eval do
      principal "User"
      tenant "User", membership: "TeamMembership", member: :user, roles: :role, self: :owner
      current_tenant :seller
      platform_role :staff
      resource "Link", tenant: :user

      grant :owner, :read, "Link"
      grant :owner, :write, "Link"
      grant :admin, :read, "Link"
      grant :admin, :write, "Link"
      grant :marketing, :read, "Link"

      %i[owner admin marketing].each { |name| term "user.role_#{name}_for?(seller)", role(name, tenant: :current) }
      next unless written

      seller_team = role(:owner, tenant: :current) | role(:admin, tenant: :current)
      rule "LinkPolicy", :edit?, guard: (seller_team | role(:marketing, tenant: :current)) & in_current_tenant
      rule "LinkPolicy", :update?, guard: fixed ? seller_team & in_current_tenant : seller_team
    end
    mapping
  end
end

# A string works as the subject as well as the policy class itself.
RSpec.describe "LinkPolicy", :hallmark do
  context "as shipped" do
    let(:hallmark_mapping) { Storefront.mapping(fixed: false) }

    it { is_expected.to have_no_counterexample(:edit?) }
    it { is_expected.not_to satisfy_catalog }

    it "explains the current-tenant confusion in update?" do
      expect { expect(subject).to have_no_counterexample(:update?) }.to raise_error(
        RSpec::Expectations::ExpectationNotMetError,
        /FAIL  LinkPolicy#update\? \(write Link\).* in tenant User\$\d, where they hold no roles/m
      )
    end
  end

  context "with the seller check" do
    let(:hallmark_mapping) { Storefront.mapping(fixed: true) }

    it { is_expected.to satisfy_catalog }
    it { is_expected.to have_no_counterexample(:update?) }
  end
end

# The same rules with no hand-written guard: read from app/policies, and
# from fixed/app/policies.
RSpec.describe "LinkPolicy", :hallmark do
  let(:hallmark_mapping) { Storefront.mapping(written: false) }

  context "read from the policy code" do
    let(:hallmark_root) { __dir__ }

    it { is_expected.to have_no_counterexample(:edit?) }
    it { is_expected.not_to have_no_counterexample(:update?) }
  end

  context "read from the fixed policy code" do
    let(:hallmark_root) { File.join(__dir__, "fixed") }

    it { is_expected.to satisfy_catalog }
  end
end
