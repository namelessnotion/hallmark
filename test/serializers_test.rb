# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# REST serializers read from code (phase 3 step 8): Grape entities on the
# DeclarativePolicy fixture's API (test/fixtures/apps/declarative_buggy),
# ActiveModel serializers and the controller rendering them on the shop
# fixture, and renderings written in a scratch app per test. No Java.
class SerializersTest < Minitest::Test
  include Hallmark::Guard::DSL

  GRAPE = File.join(HallmarkTestHelpers::FIXTURES, "apps", "declarative_buggy")
  SHOP = File.join(HallmarkTestHelpers::FIXTURES, "apps", "shop")
  FLAGS = %i[project_public public_builds archived].freeze

  def grape_mapping
    mapping = Hallmark::Mapping.new
    mapping.instance_eval do
      platform_role :admin
      tenant "Project", membership: "ProjectMember", roles: :access_level
      public_when = flag(:project_public) & flag(:public_builds)
      resource "Schedule", tenant: :project, flags: FLAGS, public_when: public_when
      resource "Project", tenant: :itself, flags: FLAGS, public_when: public_when
      %w[Schedule Project].each { |name| grant :reporter, :read, name }
      rule "SchedulePolicy", :read_schedule, op: :read
      rule "ProjectPolicy", :read_schedule, op: :read
      %w[public? public_builds? archived?].zip(FLAGS).each do |reader, name|
        term "record.#{reader}", flag(name)
        term "record.project.#{reader}", flag(name)
      end
      term "guest", role(:reporter, tenant: :record)
      term "reporter", role(:reporter, tenant: :record)
      term "ip_restricted", Hallmark::Guard.new(:never)
    end
    mapping
  end

  def shop_mapping
    mapping = Hallmark::Mapping.new
    mapping.instance_eval do
      principal "User"
      tenant "User", membership: "TeamMembership", member: :user, roles: :role, self: :owner
      current_tenant :seller, controller: :current_seller
      platform_role :staff
      resource "Link", tenant: :user, public_if: :published?
      resource "User", kind: :profile
      term "user.role_admin_for?(record.user)", role(:admin, tenant: :record)
    end
    mapping
  end

  def grape(mapping = grape_mapping) = Hallmark::Extractor.new(mapping, GRAPE)
  def shop(mapping = shop_mapping) = Hallmark::Extractor.new(mapping, SHOP)

  # Field name => condition, for one serializer read with no rendering
  # (options left as written) or with one.
  def conditions(extractor, name, rendering = nil)
    serializers = extractor.serializers
    serializers.fields(name, serializers.resource_of(name), rendering).to_h do |field|
      [field.name, field.condition.to_s]
    end
  end

  def endpoint(extractor, name) = extractor.grape.endpoint_named(name)
  def rendering(extractor, entry_point) = extractor.controllers.fetch(entry_point).renderings

  # A scratch app with `files` (path => source), read with `mapping`.
  def scratch(files, mapping)
    Dir.mktmpdir("hallmark-serializers") do |root|
      files.each do |path, source|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), source)
      end
      yield Hallmark::Extractor.new(mapping, root)
    end
  end

  def test_finds_entities_and_serializers
    assert_equal %w[API::Entities::Project API::Entities::Schedule API::Entities::ScheduleDetails
                    API::Entities::UserBasic], grape.serializers.serializers
    assert_equal %w[Admin::LinkSerializer LinkSerializer UserSerializer], shop.serializers.serializers
    assert_equal :grape, grape.serializers.dialect("API::Entities::Schedule")
    assert_equal :active_model, shop.serializers.dialect("LinkSerializer")
  end

  # Several names, `as:`, a value block, a nesting block (its fields keyed
  # under it), `merge:` changing nothing but the key, `unexpose` and
  # `override:` in the subclass.
  def test_reads_grape_fields_and_keys
    fields = grape.serializers.fields("API::Entities::ScheduleDetails", "Schedule").to_h { |each| [each.name, each] }

    assert_equal %w[id description ref owner project token internal_id next_run_at web_url status last_editor notes
                    secret audit visibility variables forks], fields.keys
    assert_equal ["branch", "links.web_url", "state"], [fields["ref"].key, fields["web_url"].key, fields["status"].key]
    assert_equal "lib/api/entities/schedule_details.rb:8", fields["description"].location
    refute_includes fields.keys, "legacy"
  end

  # A mapped nested entity is a record, not a field; an unmapped one
  # (UserBasic) is a field of the parent; a String `using:` resolves too.
  def test_reads_grape_associations
    fields = grape.serializers.fields("API::Entities::Schedule", "Schedule").to_h { |each| [each.name, each] }

    assert_equal "Project", fields["project"].resource
    assert_nil fields["owner"].resource
    assert_nil grape.serializers.resource_of("API::Entities::UserBasic")
  end

  # With no rendering, options are left as written: a Symbol and a Hash
  # read options, `unless:` negates, a one-parameter lambda reads the
  # record, `with_options` ANDs its condition with the field's own, an
  # entity method is read in place, and a class-level builder is opaque.
  def test_reads_grape_conditions
    found = conditions(grape, "API::Entities::Schedule")

    assert_equal "~opaque(`options[:hide_tokens]`)", found["token"]
    assert_equal "opaque(`options[:type] == :full`)", found["internal_id"]
    assert_equal "flag(:project_public)", found["web_url"]
    assert_equal "(opaque(`options[:current_user]`) & opaque(`options[:with_editor]`))", found["last_editor"]
    assert_equal "(opaque(`options[:current_user]`) & opaque(`options[:current_user].admin?`))", found["secret"]
    assert_equal "opaque(`can_read(:audit)`)", found["audit"]
  end

  # A reader the entity aliases to `object` (GitLab's `alias_method
  # :project, :object`) is the record, also inside a lambda that ignores
  # its parameters.
  def test_an_alias_of_object_is_the_record
    assert_equal "flag(:project_public)", conditions(grape, "API::Entities::Schedule")["visibility"]
  end

  # An EE module's `prepended do` block adds its fields through
  # `prepend_mod_with`.
  def test_reads_ee_fields
    assert_equal "flag(:archived)", conditions(grape, "API::Entities::Project")["approvals_before_merge"]
  end

  # In a rendering: the options it passes (`user: current_user`) are the
  # signed-in user, an ability on the record is the policy's, one on
  # another object stays opaque, and an option it does not pass is nil.
  def test_reads_grape_conditions_for_a_rendering
    extractor = grape
    rendering = endpoint(extractor, "GET /projects/:id/schedules/:schedule_id").renderings.fetch(0)
    found = conditions(extractor, "API::Entities::ScheduleDetails", rendering)

    assert_equal extractor.ability_guard("Schedule", "read_schedule").to_s, found["variables"]
    assert_equal "opaque(`Ability.allowed?(user, :read_schedule, record.project)`)", found["forks"]
    assert_equal %w[never never never never], found.values_at("description", "internal_id", "notes", "secret")
    assert_equal "no check", found["token"]
  end

  # A term names a condition the reader cannot read.
  def test_a_term_names_a_condition
    mapping = grape_mapping
    mapping.term "can_read(:audit)", role(:admin)

    assert_equal "role(:admin)", conditions(grape(mapping), "API::Entities::Schedule")["audit"]
  end

  # `attributes`, `attribute` with `key:`, a Symbol and a lambda `if:`,
  # `unless:`, a value block, associations with and without `serializer:`,
  # `scope` and `current_user` as the signed-in user, `instance_options`,
  # and a rule through `policy(object)`.
  def test_reads_active_model_serializers
    serializers = shop.serializers
    fields = serializers.fields("LinkSerializer", "Link").to_h { |each| [each.name, each] }

    assert_equal %w[id name revenue draft notes sales_count buyer_emails stats variants user seller_profile margin],
                 fields.keys
    assert_equal ["earnings", "role(:admin, tenant: :record)"],
                 [fields["revenue"].key, fields["revenue"].condition.to_s]
    assert_equal ["~public_record", "role(:staff)"],
                 [fields["draft"].condition.to_s, fields["buyer_emails"].condition.to_s]
    assert_equal "opaque(`instance_options[:preview]`)", fields["notes"].condition.to_s
    assert_equal [nil, "User", nil], fields.values_at("variants", "user", "seller_profile").map(&:resource)
    assert_includes fields["stats"].condition.to_s, "in_current_tenant"
  end

  # A subclass redeclares a field without its condition.
  def test_reads_active_model_inheritance
    assert_equal "no check", conditions(shop, "Admin::LinkSerializer")["buyer_emails"]
  end

  # `serialization_scope nil` leaves `current_user` as written, for a term.
  def test_serialization_scope
    files = {
      "app/controllers/links_controller.rb" => <<~RUBY,
        class LinksController < ApplicationController
          serialization_scope nil

          def show
            @link = Link.find(params[:id])
            authorize @link
            render json: @link, serializer: LinkSerializer
          end
        end
      RUBY
      "app/serializers/link_serializer.rb" => <<~RUBY
        class LinkSerializer < ActiveModel::Serializer
          attribute :revenue, if: -> { current_user.role_admin_for?(object.user) }
        end
      RUBY
    }
    scratch(files, shop_mapping) do |extractor|
      rendering = rendering(extractor, "LinksController#show").fetch(0)

      assert_nil rendering.scope
      assert_equal "opaque(`current_user.role_admin_for?(record.user)`)",
                   conditions(extractor, "LinkSerializer", rendering)["revenue"]
    end
  end

  # The resource: declared, else by name with namespaces dropped, else an
  # ancestor's.
  def test_resolves_resources
    mapping = grape_mapping
    mapping.serializer "API::Entities::UserBasic", resource: "Project"
    serializers = grape(mapping).serializers

    assert_equal "Project", serializers.resource_of("API::Entities::UserBasic")
    assert_equal "Schedule", serializers.resource_of("API::Entities::ScheduleDetails")
    assert_equal "Link", shop.serializers.resource_of("Admin::LinkSerializer")
  end

  def test_rejects_a_serializer_on_an_unmapped_resource
    mapping = shop_mapping
    mapping.serializer "LinkSerializer", resource: "Order"

    assert_raises(Hallmark::ConfigurationError) { mapping.validate! }
  end

  # `present x, with: E` resolved through the API's namespaces, a list,
  # and the record's check found by its reader.
  def test_reads_grape_renderings
    extractor = grape
    list = endpoint(extractor, "GET /projects/:id/schedules").renderings.fetch(0)
    one = endpoint(extractor, "GET /projects/:id/schedules/:schedule_id").renderings.fetch(0)

    assert list.collection
    assert_equal "API::Entities::Schedule", extractor.serializers.resolve(list)
    assert_equal ["API::Entities::ScheduleDetails", "SchedulePolicy", "read_schedule"],
                 [extractor.serializers.resolve(one), one.authorization.policy, one.authorization.rule]
    assert_equal ["user"], one.options.keys
  end

  GRAPE_API = <<~RUBY
    module API
      class Things < Grape::API
        helpers do
          def present_project(project, options = {})
            present project, options
          end

          def user_project
            @user_project ||= find_project!(params[:id])
          end
        end

        resource :projects do
          get ":id/keyed" do
            present :project, project, with: Entities::Project, current_user: current_user
          end

          get ":id/ternary" do
            present project, with: params[:simple] ? Entities::UserBasic : Entities::Project
          end

          get ":id/forwarded" do
            present_project user_project, with: Entities::Project, current_user: current_user, extra: params[:extra]
          end

          get ":id/local" do
            options = { with: Entities::Project, admin: can?(current_user, :read_schedule, project), flag: true,
                        statistics: params[:statistics], other: compute_it }
            present project, options
          end

          get ":id/unknown" do
            present project, with: entity_for(project)
          end
        end
      end
    end
  RUBY

  def grape_scratch(&)
    files = { "lib/api/things.rb" => GRAPE_API }
    paths = %w[lib/api/helpers/project_helpers.rb lib/api/entities/project.rb lib/api/entities/user_basic.rb
               app/policies/base_policy.rb app/policies/project_policy.rb app/policies/concerns/crud_policy_helpers.rb]
    paths.each { |path| files[path] = File.read(File.join(GRAPE, path)) }
    scratch(files, grape_mapping, &)
  end

  def test_reads_present_with_a_key_a_ternary_and_a_forwarding_helper
    grape_scratch do |extractor|
      keyed = endpoint(extractor, "GET /projects/:id/keyed").renderings.fetch(0)
      sides = endpoint(extractor, "GET /projects/:id/ternary").renderings
      forwarded = endpoint(extractor, "GET /projects/:id/forwarded").renderings.fetch(0)

      assert_equal ["project", "Entities::Project", %w[current_user]],
                   [keyed.source, keyed.serializer, keyed.options.keys]
      assert_equal([["Entities::UserBasic", false], ["Entities::Project", true]],
                   sides.map { |each| [each.serializer, each.branches.fetch(0).negated] })
      assert_equal ["user_project", "Entities::Project", %w[current_user extra]],
                   [forwarded.source, forwarded.serializer, forwarded.options.keys]
      assert_equal [nil, "ProjectPolicy"], [forwarded.authorization, forwarded.candidates.fetch(0).policy]
    end
  end

  # Every kind of option: the user, an ability on the rendered record, a
  # parameter (the client chooses: true), a literal, one not passed (nil),
  # and anything else (opaque).
  def test_reads_each_kind_of_option
    grape_scratch do |extractor|
      rendering = endpoint(extractor, "GET /projects/:id/local").renderings.fetch(0)
      serializers = extractor.serializers
      guard = lambda do |source|
        node = Prism.parse("->(project, options) { #{source} }").value.statements.body.first
        condition = Hallmark::Extractor::Serializers::Condition.new(kind: :lambda, node: node, negated: false,
                                                                    owner: "API::Entities::Project", file: "x.rb")
        serializers.condition_guard(condition, "Project", rendering)
      end

      assert_equal "API::Entities::Project", serializers.resolve(rendering)
      assert_equal extractor.ability_guard("Project", "read_schedule"), guard.call("options[:admin]")
      assert_equal(["no check", "no check", "never"],
                   %w[options[:statistics] options[:flag] options[:missing]].map { |each| guard.call(each).to_s })
      assert_equal "opaque(`compute_it`)", guard.call("options[:other]").to_s
    end
  end

  def test_an_unknown_entity_is_kept_as_unknown
    grape_scratch do |extractor|
      rendering = endpoint(extractor, "GET /projects/:id/unknown").renderings.fetch(0)

      assert_equal "with: entity_for(project)", rendering.unknown
      assert_nil extractor.serializers.resolve(rendering)
    end
  end

  # `render json:` with `serializer:`, `each_serializer:`, no serializer
  # (the model's), in a branch (both sides), in a callback's helper, JSON
  # another render made (skipped), and a serializer Hallmark cannot tell.
  def test_reads_rails_renderings
    extractor = shop
    serializers = extractor.serializers
    show = rendering(extractor, "Api::LinksController#show").fetch(0)
    preview = rendering(extractor, "Api::LinksController#preview")
    index = rendering(extractor, "Api::LinksController#index").fetch(0)

    assert_equal %w[LinkSerializer LinkPolicy], [serializers.resolve(show), show.authorization.policy]
    assert_equal([[false, "LinkSerializer"], [true, "LinkSerializer"]],
                 preview.map { |each| [each.branches.fetch(0).negated, serializers.resolve(each, "Link")] })
    assert_equal [true, nil], [index.collection, index.authorization]
    assert_equal ["Admin::LinkSerializer"], rendering(extractor, "Api::LinksController#staff").map(&:serializer)
    assert_equal(["source_requested"], rendering(extractor, "Api::LinksController#export").flat_map { _1.options.keys })
    assert_equal "serializer: serializer_for(@link)", rendering(extractor, "Api::LinksController#unknown").fetch(0).unknown
  end

  # A branch's condition, read as the controller's checks are.
  def test_reads_a_rendering_branch
    extractor = shop
    branches = rendering(extractor, "Api::LinksController#preview").map { |each| each.branches.fetch(0) }

    assert_equal(["in_current_tenant", "~in_current_tenant"],
                 branches.map do |each|
                   extractor.controllers.branch_guard("Api::LinksController#preview", each, "Link").to_s
                 end)
  end

  def test_counts_jbuilder_views
    scratch({ "app/views/links/show.json.jbuilder" => "json.id @link.id\n",
              "app/serializers/link_serializer.rb" => "class LinkSerializer < ActiveModel::Serializer; end\n" },
            shop_mapping) do |extractor|
      assert_equal 1, extractor.serializers.jbuilder_views
    end
  end
end
