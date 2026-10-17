# frozen_string_literal: true

require "test_helper"
require_relative "collectors/shop_people"

# The whole loop: drive the same two rules through an Action Policy
# controller and a Pundit controller, write stamps, infer guards, and get
# the findings a hand-written mapping of those rules gets.
class InferredFindingsTest < Minitest::Test
  include ShopPeople

  CONTROLLERS = [ApShop::LinksController, PunditShop::LinksController].freeze

  def drive
    collect do
      CONTROLLERS.each do |controller|
        Shop.request(controller, :edit, user: @ann, seller: @ann, link: @ann_link)
        Shop.request(controller, :edit, user: @mia, seller: @ann, link: @ann_link)
        Shop.request(controller, :edit, user: @ada, seller: @ann, link: @bob_link) # denied: not the seller's
        Shop.request(controller, :edit, link: @ann_link)                           # denied: anonymous
        Shop.request(controller, :update, user: @ann, seller: @ann, link: @ann_link)
        Shop.request(controller, :update, user: @ada, seller: @ann, link: @bob_link) # M2: allowed
        Shop.request(controller, :update, user: @mia, seller: @ann, link: @ann_link) # denied
      end
    end
  end

  def inferred
    set = drive
    Hallmark::Analysis.build("Inferred", mapping: Shop.map(Hallmark::Mapping.new)) { stamps set }
  end

  def hand_written
    Hallmark::Analysis.build("Hand-written", mapping: Shop.map(Hallmark::Mapping.new)) do
      team = role(:owner, tenant: :current) | role(:admin, tenant: :current)
      %w[ApShop PunditShop].each do |app|
        reads "#{app}::LinksController#edit", "Shop::Link",
              guard: logged_in & (team | role(:marketing, tenant: :current)) & in_current_tenant
        writes "#{app}::LinksController#update", "Shop::Link", guard: logged_in & team
      end
    end
  end

  def summary(exposures) = exposures.map { |exposure| [exposure.action, exposure.op, exposure.resource] }.sort

  def test_infers_the_same_exposures_as_the_hand_written_mapping
    assert_equal summary(hand_written.exposures), summary(inferred.exposures)
  end

  def test_both_libraries_infer_the_same_guards
    guards = inferred.exposures.group_by { |exposure| exposure.action.split("::", 2).last }
                     .transform_values { |pair| pair.map { |exposure| exposure.guard.to_s }.uniq }

    assert_equal({ "LinksController#edit" => 1, "LinksController#update" => 1 }, guards.transform_values(&:size))
  end

  def test_gets_the_same_findings_as_the_hand_written_mapping
    solver = require_solver!
    expected = hand_written.run(solver: solver)
    actual = inferred.run(solver: solver)

    assert_equal %w[ApShop::LinksController#update PunditShop::LinksController#update],
                 actual.findings.map { |finding| finding.exposure.action }.sort
    assert_equal expected.findings.map { |finding| [finding.exposure.action, finding.pattern] }.sort,
                 actual.findings.map { |finding| [finding.exposure.action, finding.pattern] }.sort
    assert(actual.findings.all?(&:cross_tenant?))
    assert_equal summary(expected.verified), summary(actual.verified)
    assert_includes actual.to_s, "inferred from 2 allow-stamps of ApShop::LinkPolicy#update?"
    assert_includes actual.to_s, "Not observed (coverage gaps, not findings):"
  end
end
