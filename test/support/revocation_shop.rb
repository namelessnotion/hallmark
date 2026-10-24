# frozen_string_literal: true

# Active Record models on SQLite in memory for the revocations collector's
# tests (phase 3 step 9), written for them: users who sell, team
# memberships with a role and a soft-delete column, GitLab-shaped members
# of a polymorphic source with an access level, and products. Tables carry
# an `rs_` prefix so they share a connection with nothing else.

require "active_record"
require "sqlite3"

module RevocationShop
  class << self
    def connect!
      return if @connected

      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      ActiveRecord::Schema.verbose = false
      ActiveRecord::Schema.define { RevocationShop.schema(self) }
      @connected = true
    end

    def schema(schema)
      schema.create_table(:rs_users) { |t| t.string :name }
      schema.create_table(:rs_memberships) do |t|
        t.references :user
        t.references :seller
        t.string :role
        t.datetime :deleted_at
      end
      schema.create_table(:rs_groups) { |t| t.string :name }
      schema.create_table(:rs_members) do |t|
        t.references :user
        t.references :source, polymorphic: true
        t.integer :access_level
      end
      schema.create_table(:rs_links) { |t| t.references :user }
    end

    def reset!
      [Membership, Member, Link, Group, User].each(&:delete_all)
    end

    # The mapping an app would declare; `roles_in` reads the table unless
    # given another reader.
    def map(mapping, membership: "RevocationShop::Membership", within: :seller, soft_delete: :deleted_at, roles_in: nil,
            roles: :role, role_names: nil)
      reader = roles_in || ->(user, seller) { Membership.where(user:, seller:, deleted_at: nil).pluck(:role) }
      mapping.instance_eval do
        principal "RevocationShop::User"
        tenant "RevocationShop::User", membership: membership, member: :user, roles: roles, self: :owner,
                                       roles_in: reader, within: within, soft_delete: soft_delete,
                                       role_names: role_names
        current_tenant :seller
        resource "RevocationShop::Link", tenant: :user
        grant :admin, :write, "RevocationShop::Link"
      end
      mapping
    end
  end

  class Record < ActiveRecord::Base
    self.abstract_class = true
  end

  class User < Record
    self.table_name = "rs_users"
  end

  class Membership < Record
    self.table_name = "rs_memberships"
    belongs_to :user, class_name: "RevocationShop::User"
    belongs_to :seller, class_name: "RevocationShop::User"
  end

  class Group < Record
    self.table_name = "rs_groups"
  end

  # GitLab's shape: a member of a group or a project, by access level.
  class Member < Record
    self.table_name = "rs_members"
    belongs_to :user, class_name: "RevocationShop::User"
    belongs_to :source, polymorphic: true
  end

  # A subclass of the watched class, as GitLab's ProjectMember < Member.
  class GroupMember < Member
  end

  class Link < Record
    self.table_name = "rs_links"
    belongs_to :user, class_name: "RevocationShop::User"
  end

  # What a policy hands the collectors: the user and the current seller.
  Policy = Struct.new(:user, :seller)
end
