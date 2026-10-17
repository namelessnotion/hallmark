# frozen_string_literal: true

# A small Gumroad-shaped shop for the collector tests, written for them (no
# app code is copied): every user can sell products (links), a seller's team
# members act for that seller with per-seller roles, and the vendor's staff
# may change anything. The same two rules are written for each library:
#
#   edit?   owner, admin or marketing of the current seller, and the link is
#           the current seller's
#   update? owner or admin of the current seller; never checks whose link it
#           is (M2, current-tenant confusion)
#
# Each library also has a rule with no record, for the vendor's staff only:
# a headless dashboard policy (Pundit, Action Policy) checked against the
# Symbol :dashboard, and a DeclarativePolicy global ability on :global.

require "action_controller"
require "action_policy"
require "action_policy/rails/controller"
require "action_policy/rails/authorizer"
require "declarative_policy"
require "pundit"
require "tmpdir"

# What Action Policy's railtie does when its instrumentation is on (the
# default), so `authorize!` fires `action_policy.authorize`.
ActionPolicy::Authorizer.singleton_class.prepend(ActionPolicy::Rails::Authorizer)

module Shop
  class User
    attr_reader :name

    def initialize(name, staff: false)
      @name = name
      @staff = staff
    end

    def staff? = @staff

    # A seller is the owner of its own shop; everyone else holds the roles
    # their team membership gives them.
    def team_roles_for(seller)
      return ["owner"] if seller == self

      Shop.memberships.fetch([self, seller], [])
    end

    # A collaborator on another seller's link: :write, or false.
    def collaborator_for?(link) = Shop.collaborations.include?([self, link]) && :write

    def inspect = "#<Shop::User #{name}>"
  end

  class Link
    attr_reader :user

    def initialize(user)
      @user = user
    end
  end

  # The request a test controller serves: who is signed in, which seller
  # they act for, and which link the id names.
  Session = Struct.new(:user, :seller, :link)

  class << self
    attr_accessor :session, :denied_query

    def memberships = @memberships ||= {}
    def collaborations = @collaborations ||= []
  end

  # The mapping, as an app would declare it in config/hallmark.rb.
  def self.map(mapping, current_tenant: :seller)
    current = current_tenant
    mapping.instance_eval do
      principal "Shop::User", roles: ->(user) { user.staff? ? ["staff"] : [] }
      tenant "Shop::User", membership: "Shop::TeamMembership", self: :owner, roles_in: :team_roles_for
      current_tenant current
      platform_role :staff
      resource "Shop::Link", tenant: :user, permits: :collaborator_for?

      grant :owner, :read, "Shop::Link"
      grant :owner, :write, "Shop::Link"
      grant :admin, :read, "Shop::Link"
      grant :admin, :write, "Shop::Link"
      grant :marketing, :read, "Shop::Link"
    end
    mapping
  end

  # Serves one request through a test controller, as a GET unless `verb`
  # names another HTTP method ("PATCH").
  def self.request(controller, action, user: nil, seller: nil, link: nil, verb: "GET")
    self.session = Session.new(user, seller, link)
    status, = controller.action(action).call(Rack::MockRequest.env_for("/links/1", method: verb))
    status
  ensure
    self.session = nil
  end
end

module ApShop
  class LinkPolicy < ActionPolicy::Base
    authorize :user, allow_nil: true
    authorize :seller, allow_nil: true

    def edit? = team?("owner", "admin", "marketing") && record.user == seller
    def update? = team?("owner", "admin")
    # Raises for a non-member, like Gumroad's role_admin_for?
    def destroy? = raise(KeyError, "no membership")

    private

    def team?(*roles) = !user.nil? && !seller.nil? && user.team_roles_for(seller).intersect?(roles)
  end

  # Headless: authorized against the Symbol :dashboard, not a record.
  class DashboardPolicy < ActionPolicy::Base
    authorize :user, allow_nil: true
    authorize :seller, allow_nil: true

    def show? = !user.nil? && user.staff?
  end

  class DashboardsController < ActionController::Base
    include ActionPolicy::Controller

    authorize :user, through: :current_user
    authorize :seller, through: :current_seller

    rescue_from(ActionPolicy::Unauthorized) { head :forbidden }

    def show
      authorize! :dashboard, to: :show?, with: DashboardPolicy
      head :ok
    end

    private

    def current_user = Shop.session.user
    def current_seller = Shop.session.seller
  end

  class LinksController < ActionController::Base
    include ActionPolicy::Controller

    authorize :user, through: :current_user
    authorize :seller, through: :current_seller

    rescue_from(ActionPolicy::Unauthorized) { head :forbidden }

    def edit
      authorize! Shop.session.link, with: LinkPolicy
      head :ok
    end

    def update
      allowed_to?(:edit?, Shop.session.link, with: LinkPolicy) # a query, as a view would make
      authorize! Shop.session.link, with: LinkPolicy
      head :ok
    end

    def destroy
      authorize! Shop.session.link, with: LinkPolicy
      head :ok
    end

    private

    def current_user = Shop.session.user
    def current_seller = Shop.session.seller
  end
end

module PunditShop
  # Gumroad passes its policies a context holding the user and the seller.
  Context = Struct.new(:user, :seller)

  class LinkPolicy
    attr_reader :user, :seller, :record

    def initialize(context, record)
      @user = context.user
      @seller = context.seller
      @record = record
    end

    def edit? = team?("owner", "admin", "marketing") && record.user == seller
    def update? = team?("owner", "admin")

    private

    def team?(*roles) = !user.nil? && !seller.nil? && user.team_roles_for(seller).intersect?(roles)
  end

  # Headless, as Pundit documents it: the record is the Symbol :dashboard
  # (or the last element of a namespaced array such as [:admin, :dashboard]).
  class DashboardPolicy
    attr_reader :user, :seller, :record

    def initialize(context, record)
      @user = context.user
      @seller = context.seller
      @record = record
    end

    def show? = !user.nil? && user.staff?
  end

  # A service object authorizing the headless policy outside any request.
  class DashboardReport
    include Pundit::Authorization

    def initialize(user, seller)
      @context = Context.new(user, seller)
    end

    def build(record = :dashboard) = authorize(record, :show?, policy_class: DashboardPolicy)

    private

    def pundit_user = @context
  end

  # Not a controller: a service object that authorizes outside any request,
  # so it has no `action_name`.
  class ProductPublisher
    include Pundit::Authorization

    def initialize(user, seller)
      @context = Context.new(user, seller)
    end

    def publish(link, query = :update?) = authorize(link, query, policy_class: LinkPolicy)

    private

    def pundit_user = @context
  end

  class LinksController < ActionController::Base
    include Pundit::Authorization

    rescue_from(Pundit::NotAuthorizedError) do |error|
      Shop.denied_query = error.query
      head :forbidden
    end
    before_action :require_seller, only: :index

    def edit
      authorize Shop.session.link, policy_class: LinkPolicy
      head :ok
    end

    def update
      authorize Shop.session.link, policy_class: LinkPolicy
      head :ok
    end

    # Names its rule, as a Symbol
    def publish
      authorize Shop.session.link, :update?, policy_class: LinkPolicy
      head :ok
    end

    # Threat 10: renders without any authorization call
    def show = head(:ok)

    # Redirects before authorizing when no link is found, as an action body
    # that checks a feature flag first would; otherwise authorizes and renders.
    def preview
      return redirect_to("/links") unless Shop.session.link

      authorize Shop.session.link, :edit?, policy_class: LinkPolicy
      head :ok
    end

    # Redirects without ever authorizing, as a signed-URL download would.
    def archive = redirect_to("/archive/1")

    def index = head(:ok)

    def missing = head(:not_found)

    private

    def pundit_user = Context.new(Shop.session.user, Shop.session.seller)

    def require_seller
      redirect_to "/sign_in" unless Shop.session.seller
    end
  end
end

module DpShop
  class LinkPolicy < DeclarativePolicy::Base
    condition(:team_admin) { !@user.nil? && @user.team_roles_for(@subject.user).intersect?(%w[owner admin]) }
    condition(:broken) { raise KeyError, "no membership" }
    condition(:signed_in) { !@user.nil? }

    rule { team_admin }.enable :update_link
    rule { signed_in }.enable :create_link
    rule { broken }.enable :archive_link
    rule { team_admin }.enable :feature_link
  end

  # A global ability, as GitLab's GlobalPolicy has: the subject is :global.
  class GlobalPolicy < DeclarativePolicy::Base
    condition(:staff, scope: :user) { !@user.nil? && @user.staff? }

    rule { staff }.enable :read_admin_dashboard
  end
end
