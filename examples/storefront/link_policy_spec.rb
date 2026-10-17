# frozen_string_literal: true

# Storefront's LinkPolicy checked with the RSpec matchers from
# `hallmark/rspec`. The guards are hand-written (`rule ..., guard:`) and
# summarize the policy as README.md shows it; in an app they are usually
# inferred from the stamps the rest of the suite records, and the mapping
# comes from config/hallmark.rb. Here each context swaps in its own mapping
# with `let(:hallmark_mapping)`: as shipped, and with the fix.
#
# Run: bundle exec rspec examples/storefront/link_policy_spec.rb

require "hallmark/rspec"

# The example's mapping.
module Storefront
  # The mapping from hallmark.rb, plus LinkPolicy's rules. `fixed:` adds the
  # seller check that update? lacks.
  def self.mapping(fixed:)
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
