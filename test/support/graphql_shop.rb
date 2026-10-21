# frozen_string_literal: true

# A GraphQL API over the test shop (test/support/shop.rb), for the
# graphql-ruby collector, written for these tests:
#
#   Query.link(id:)             a link; LinkType's `authorized?` is plain
#                               Ruby (a member of the link's seller's team)
#   Query.product(id:)          the same link as ProductType, whose
#                               `authorized?` only asks a DeclarativePolicy
#                               rule, as GitLab's types do
#   Query.seller(name:)         a seller (UserType, signed-in viewers only)
#     links, linksConnection    the seller's links, as a list and a connection
#   Query.lazyLink(id:)         resolved lazily; the lazy block checks a rule
#   LinkType.editable           a field whose resolver checks a rule
#   Mutation.linkRename(id:)    checks a rule in its resolver
#
# The context carries `current_user` and `current_seller`; `explode` makes
# LinkType's check raise. LegacySchema is the same API traced through 1.x's
# `tracer`, and GraphqlController serves Schema as GitLab's controller does.

require "graphql"
require "hallmark/collectors/graphql"
require_relative "shop"

module GraphqlShop
  class << self
    # Links by id, and sellers by name.
    def links = @links ||= {}
    def sellers = @sellers ||= {}
  end

  # Read access for any member of the link's seller's team.
  class ProductPolicy < DeclarativePolicy::Base
    condition(:team_member) { !@user.nil? && !@user.team_roles_for(@subject.user).empty? }

    rule { team_member }.enable :read_product
  end

  class LinkType < GraphQL::Schema::Object
    field :id, ID, null: false
    field :seller, "GraphqlShop::UserType", null: false, method: :user
    field :editable, Boolean, null: false, resolver_method: :editable?

    def self.authorized?(link, context)
      raise KeyError, "no membership" if context[:explode]

      user = context[:current_user]
      !user.nil? && !user.team_roles_for(link.user).empty?
    end

    def id = GraphqlShop.links.key(object)

    def editable? = DpShop::LinkPolicy.new(context[:current_user], object).allowed?(:update_link)
  end

  class ProductType < GraphQL::Schema::Object
    field :id, ID, null: false

    def self.authorized?(link, context) = ProductPolicy.new(context[:current_user], link).allowed?(:read_product)

    def id = GraphqlShop.links.key(object)
  end

  class UserType < GraphQL::Schema::Object
    field :name, String, null: false
    field :links, [LinkType], null: false
    field :links_connection, LinkType.connection_type, null: false

    def self.authorized?(_user, context) = !context[:current_user].nil?

    def links = GraphqlShop.links.values.select { |link| link.user.equal?(object) }
    def links_connection = links
  end

  class QueryType < GraphQL::Schema::Object
    field :link, LinkType do
      argument :id, ID, as: :key
    end
    field :product, ProductType do
      argument :id, ID, as: :key
    end
    field :seller, UserType do
      argument :name, String
    end
    field :lazy_link, LinkType do
      argument :id, ID, as: :key
    end

    def link(key:) = GraphqlShop.links[key]
    def product(key:) = GraphqlShop.links[key]
    def seller(name:) = GraphqlShop.sellers[name]

    # As a batch loader would: the rule runs when the lazy value is synced,
    # outside any field's resolver.
    def lazy_link(key:)
      user = context[:current_user]
      GraphQL::Execution::Lazy.new do
        link = GraphqlShop.links[key]
        link if DpShop::LinkPolicy.new(user, link).allowed?(:update_link)
      end
    end
  end

  class LinkRename < GraphQL::Schema::Mutation
    argument :id, ID, as: :key
    field :link, LinkType

    def resolve(key:)
      link = GraphqlShop.links[key]
      { link: (link if DpShop::LinkPolicy.new(context[:current_user], link).allowed?(:update_link)) }
    end
  end

  class MutationType < GraphQL::Schema::Object
    field :link_rename, mutation: LinkRename
  end

  class Schema < GraphQL::Schema
    query QueryType
    mutation MutationType
  end

  # The same schema given 1.x's tracer by hand: graphql-ruby 2.x calls it
  # through its legacy-tracer bridge, with the arguments 1.x passes.
  class LegacySchema < GraphQL::Schema
    query QueryType
    mutation MutationType
    tracer Hallmark::Collectors::GraphqlHook::LegacyTracer, silence_deprecation_warning: true
  end

  # Served by a controller, as GitLab's GraphqlController serves its schema:
  # the query and the context's seller (the controller's current seller
  # unless `context_seller` names another) come from the test.
  class GraphqlController < ActionController::Base
    class << self
      attr_accessor :query, :context_seller
    end

    def execute
      seller = self.class.context_seller || current_seller
      result = Schema.execute(self.class.query, context: { current_user: current_user, current_seller: seller })
      render json: result.to_h
    end

    private

    def current_user = Shop.session.user
    def current_seller = Shop.session.seller
  end
end
