# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require_relative "shop_people"

# The hot path (phase 3 step 1): sampling decided before any fact is read,
# once per request, and each user's roles in a tenant read once per request.
class SamplingTest < Minitest::Test
  include ShopPeople

  EDIT = "PunditShop::LinksController#edit"
  SHOW = "PunditShop::LinksController#show"

  def test_a_request_not_sampled_is_neither_stamped_nor_flagged_unchecked
    set = collect(sample_rate: 0.0) do
      assert_equal 200, Shop.request(PunditShop::LinksController, :edit, user: @ann, seller: @ann, link: @ann_link)
      assert_equal 200, Shop.request(PunditShop::LinksController, :show, user: @ann, seller: @ann)
    end

    assert_empty set.stamps
    assert_empty set.unchecked
  end

  # Threat 10 needs the request to know a rule ran even when nothing is
  # stamped.
  def test_a_decision_not_sampled_still_counts_as_a_check
    checked = nil
    collect(sample_rate: 0.0) do
      Hallmark::Collectors.within_entry_point(EDIT) do |request|
        PunditShop::LinkPolicy.new(PunditShop::Context.new(@ann, @ann), @ann_link).edit?
        checked = request.checked
      end
    end

    assert checked
  end

  # One roll per request: its decisions are all stamped or none.
  def test_a_request_rolls_once_for_all_its_decisions
    rolls = 0
    roll = lambda do
      rolls += 1
      rolls == 1 ? 0.9 : 0.1
    end
    set = Kernel.stub(:rand, roll) do
      collect(sample_rate: 0.5) do
        2.times { Shop.request(PunditShop::LinksController, :update, user: @ann, seller: @ann, link: @ann_link) }
      end
    end

    assert_equal 2, rolls
    assert_equal 1, set.stamps.size
  end

  def test_an_entry_point_inside_another_keeps_its_sampling_and_role_reads
    inner = nil
    outer = nil
    collect(sample_rate: 0.0) do
      Hallmark::Collectors.within_entry_point(EDIT) do |request|
        request.roles = {}.compare_by_identity
        outer = request
        Hallmark::Collectors.within_entry_point("GraphQL") { |nested| inner = nested }
      end
    end

    assert_equal [false, outer&.roles], [inner&.sampled, inner&.roles]
  end

  def test_the_sample_rate_is_a_share
    mapping = Shop.map(Hallmark::Mapping.new)

    assert_raises(Hallmark::ConfigurationError) do
      Hallmark::Collectors.install!(mapping: mapping, store: Hallmark::StampStore.new("tmp"), sample_rate: 1.5)
    end
  end

  # Gumroad's mapping reads a user's roles in a seller with a query; a
  # request reads them once however many rules it checks.
  def test_a_request_reads_each_users_roles_in_a_tenant_once
    reads = count_role_reads do
      Hallmark::Collectors.within_entry_point(EDIT) do
        3.times { PunditShop::LinkPolicy.new(PunditShop::Context.new(@ada, @ann), @ann_link).edit? }
      end
    end

    assert_equal 1, reads
  end

  # Outside a request nothing is kept between decisions, but a decision
  # whose record lives in the current tenant reads the roles there once.
  def test_outside_a_request_each_decision_reads_the_roles_once
    reads = count_role_reads do
      2.times { PunditShop::LinkPolicy.new(PunditShop::Context.new(@ada, @ann), @ann_link).edit? }
    end

    assert_equal 2, reads
  end

  private

  # Counts the mapping's reads of `team_roles_for` (the policy calls it too).
  def count_role_reads(&)
    reads = 0
    Shop::User.class_eval do
      alias_method :hallmark_original_team_roles_for, :team_roles_for
      define_method(:team_roles_for) do |seller|
        caller = caller_locations(1, 1)&.first
        reads += 1 if caller&.path&.end_with?("lib/hallmark/collectors.rb")
        hallmark_original_team_roles_for(seller)
      end
    end
    set = collect(&)

    assert_equal 1, set.stamps.size
    reads
  ensure
    Shop::User.class_eval do
      alias_method :team_roles_for, :hallmark_original_team_roles_for
      remove_method :hallmark_original_team_roles_for
    end
  end
end
