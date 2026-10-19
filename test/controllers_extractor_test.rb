# frozen_string_literal: true

require "test_helper"

# Controllers read from the shop fixture's code (phase 2 step 3): how each
# entry point loads the record it authorizes, and whether it is exempt from
# verify_authorized. No Java.
class ControllersExtractorTest < Minitest::Test
  ROOT = File.join(HallmarkTestHelpers::FIXTURES, "apps", "shop")

  def controllers(reader: :current_seller)
    mapping = Hallmark::Mapping.new
    mapping.current_tenant(:seller, controller: reader)
    mapping.resource("Link", tenant: :user)
    Hallmark::Extractor::Controllers.new(mapping, ROOT)
  end

  def loading(entry_point, **) = controllers(**).fetch(entry_point)&.loading

  # A before_action sets the instance variable from the model class.
  def test_a_record_found_by_id_alone_is_unscoped
    read = controllers.fetch("LinksController#edit")

    assert_equal :unscoped, read.loading
    assert_equal "app/controllers/links_controller.rb:16", read.location
  end

  def test_a_record_found_through_the_current_tenant_is_scoped
    assert_equal :scoped, loading("LinksController#destroy")
    assert_predicate controllers.fetch("LinksController#destroy"), :scoped?
    # Through a memoizing helper.
    assert_equal :scoped, loading("LinksController#archive")
  end

  # `x || e404` loads x; Pundit's `[:seller, link]` checks link.
  def test_reads_a_way_out_and_a_namespaced_record
    assert_equal :unscoped, loading("LinksController#publish")
  end

  # skip_before_action drops the parent's unscoped filter.
  def test_a_subclass_filter_replaces_the_parents
    assert_equal :scoped, loading("Seller::LinksController#edit")
  end

  def test_unknown_roots_and_classes
    assert_equal :unknown, loading("LinksController#preview")
    assert_nil loading("LinksController#index")
    assert_nil loading("LinksController#show")
    assert_nil controllers.fetch("MissingController#show")
  end

  # A load filtered by the resource's tenant (`tenant: :user`) is scoped;
  # a filter on another column is not.
  def test_a_load_filtered_by_the_tenant_keyword_is_scoped
    assert_equal :scoped, loading("LinksController#duplicate")
    assert_equal :scoped, loading("LinksController#variants")
    assert_equal :unscoped, loading("LinksController#copy")
  end

  # The policy from the record's class (or Pundit's namespace), the rule
  # from the call or the action.
  def test_resolves_the_rule_an_authorize_call_checks
    rules = %w[edit destroy publish variants preview].to_h do |action|
      [action, controllers.fetch("LinksController##{action}").authorizations.map { |found| [found.policy, found.rule] }]
    end

    assert_equal({ "edit" => [%w[LinkPolicy edit?]], "destroy" => [%w[LinkPolicy destroy?]],
                   "publish" => [%w[Seller::LinkPolicy publish?]], "variants" => [%w[LinkPolicy index?]],
                   "preview" => [[nil, "preview?"]] }, rules)
    assert controllers.fetch("LinksController#edit").checked
    refute controllers.fetch("Admin::ReportsController#index").checked
  end

  # Without the controllers' reader nothing can be scoped.
  def test_needs_the_mappings_controller_reader
    assert_equal :unknown, loading("LinksController#destroy", reader: nil)
  end

  def test_reads_verify_authorized_exemptions
    assert_equal :skipped, controllers.fetch("LinksController#show").verify
    assert_equal :required, controllers.fetch("LinksController#edit").verify
    assert_equal :skipped, controllers.fetch("Seller::LinksController#update").verify
    assert_nil controllers.fetch("Admin::ReportsController#index").verify
  end
end
