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

  # The mapping the checks need: the platform role and the explicit
  # permission they read, and the controllers' user reader.
  def checks(entry_point, user: :current_user)
    mapping = Hallmark::Mapping.new
    mapping.principal("User", controller: user)
    mapping.current_tenant(:seller, controller: :current_seller)
    mapping.platform_role :staff
    mapping.resource("Link", tenant: :user, permits: :collaborator_for?)
    Hallmark::Extractor::Controllers.new(mapping, ROOT).checks(entry_point, "Link")
                                    .map { |check| [check.guard.to_s, check.location] }
  end

  APP = "app/controllers/application_controller.rb"
  PRODUCTS = "app/controllers/products_controller.rb"

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

  # Gumroad's shape: a shared filter loads the record and leaves unless a
  # helper says the current seller or a collaborator may reach it. The
  # helper is read in place, its argument bound to the record.
  def test_reads_a_filters_check_on_the_record
    expected = [["(in_current_tenant | permitted)", "#{APP}:21"]]

    assert_equal expected, checks("ProductsController#publish")
    assert_equal expected, checks("ProductsController#unpublish")
    assert_equal [["(in_current_tenant | permitted)", "#{PRODUCTS}:32"]], checks("ProductsController#archive")
  end

  # `return head(...) if link.user != current_seller` in the action, on a
  # local record.
  def test_reads_a_check_in_the_action
    assert_equal [["in_current_tenant", "#{PRODUCTS}:25"]], checks("ProductsController#show")
  end

  # Without the user reader, `current_user&.collaborator_for?(link)` is a
  # call Hallmark cannot read.
  def test_needs_the_mappings_user_reader
    assert_equal [["(in_current_tenant | opaque(`current_user.collaborator_for?(record)`))", "#{APP}:21"]],
                 checks("ProductsController#publish", user: nil)
  end

  # A condition on the record Hallmark cannot read is kept, with its opaque
  # leaf; one on the user alone counts when it is read exactly.
  def test_reads_unreadable_checks_on_the_record_and_exact_ones_on_the_user
    assert_equal [["opaque(`record.previewable?`)", "#{PRODUCTS}:39"]], checks("ProductsController#preview")
    assert_equal [["role(:staff)", "#{PRODUCTS}:66"]], checks("ProductsController#feature")
  end

  # `return unless request.xhr?` names neither; the way out inside a branch
  # may not run, a render in the action does not end it, and one after the
  # authorize call (in #unpublish) is the action's own logic.
  def test_skips_ways_out_it_cannot_tie_to_the_request
    assert_empty checks("ProductsController#stats")
    assert_empty checks("LinksController#edit")
    assert_empty checks("MissingController#show")
  end
end
