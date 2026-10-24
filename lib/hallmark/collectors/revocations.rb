# typed: strict
# frozen_string_literal: true

module Hallmark
  module Collectors
    # The test-mode revocations collector (threat 9, phase 3 step 9): an
    # `after_commit` on the mapped membership class notes, in process memory
    # only, each user and tenant whose roles there shrank. A later allow by
    # that user, on a record in that tenant or with that tenant current,
    # whose freshly read roles lack a revoked role, is stamped
    # `after_revocation` (`Facts#stamp`), and inference judges it
    # (`StaleAccess`).
    #
    # The callback reads only the committed row: the roles attribute before
    # and after the save (or the soft-delete attribute, or a destroy), and
    # the user's and tenant's foreign keys, never an association and never
    # the mapping's `roles_in:` reader, which is the app's code and could
    # fill a memo or a cache the app then reads. References ("User:42",
    # by base class) stay in this process; nothing about them is written.
    #
    # The noted pairs are cleared before each test example, through a
    # prepended `before_setup` on ActiveRecord::TestFixtures (Minitest's
    # Rails tests and rspec-rails both call it). A membership commit also
    # clears the current request's role reads (`Request#roles`), so a
    # request that changes roles and then authorizes reads them afresh.
    #
    # Only in test mode: the Railtie passes `revocations: true` to
    # `Collectors.install!` there and nowhere else. Never added to
    # ActiveRecord::Base itself, which would give every model a
    # transactional callback.
    module Revocations
      # What a membership row stores, from the mapping's `tenant`.
      Watch = Struct.new(:membership, :member, :within, :roles, :soft_delete, :role_names, keyword_init: true)

      # The noted pairs: a user reference, then a tenant reference, then the
      # sorted, frozen role names revoked there and not granted again. A
      # Capybara server commits in another thread, so writes take a lock;
      # reads replace nothing in place and take none.
      class Noted
        def initialize
          @lock = Mutex.new
          @pairs = {}
        end

        def empty? = @pairs.empty?

        # The role names revoked from `user`, by tenant; nil for none.
        def [](user) = @pairs[user]

        # One commit's change: roles granted now leave the revoked set, and
        # roles removed now join it; an empty set drops the pair.
        def update(user, tenant, removed:, held:)
          @lock.synchronize do
            tenants = @pairs[user] || {}
            revoked = (((tenants[tenant] || []) - held) | removed).sort.freeze
            if revoked.empty?
              tenants.delete(tenant)
            else
              tenants[tenant] = revoked
            end
            tenants.empty? ? @pairs.delete(user) : @pairs[user] = tenants
          end
        end

        def clear = @lock.synchronize { @pairs.clear }

        # A copy, for tests.
        def to_h = @lock.synchronize { @pairs.transform_values(&:dup) }
      end

      # The callback the membership class runs after each commit.
      module Callback
        private

        def hallmark_revocations_committed = Revocations.committed(self)
      end

      # Clears the noted pairs before each test example.
      module FixtureReset
        def before_setup
          Revocations.noted&.clear
          super
        end
      end

      class << self
        attr_reader :noted, :watch

        # Starts watching the mapping's membership class; returns the noted
        # pairs, or nil when there is nothing to watch: no tenant, or no
        # `membership:` or `within:` (recorded as a `RevocationsUnwatched`
        # line, listed under coverage).
        def install(mapping, store)
          @store = store
          @watch = nil
          @noted = nil
          @warned = false
          tenancy = mapping.tenancy
          return nil unless tenancy

          membership = tenancy.membership
          within = tenancy.within
          unless membership && within
            missing = [("`membership:`" unless membership), ("`within:`" unless within)].compact.join(" and ")
            return unwatched("tenant #{tenancy.name} maps no #{missing}, so the revocations collector watched " \
                             "no membership")
          end

          @watch = Watch.new(membership: membership, member: tenancy.member, within: within, roles: tenancy.roles,
                             soft_delete: tenancy.soft_delete, role_names: tenancy.role_names)
          @noted = Noted.new
          ::ActiveSupport.on_load(:active_record) { Revocations.attach }
          @noted
        end

        # Stops noting; the callback stays on the class but does nothing.
        def uninstall
          @watch = nil
          @noted = nil
        end

        # Adds the callback to the membership class, once per class, and
        # the per-example reset. A class that does not load warns once and
        # watches nothing.
        def attach
          watch = @watch
          return unless watch

          klass = Object.const_get(watch.membership)
          unless klass.include?(Callback)
            klass.include(Callback)
            klass.after_commit(:hallmark_revocations_committed)
          end
          reset_per_example
        rescue NameError => e
          @watch = nil
          @noted = nil
          warn_load(watch&.membership, e)
        end

        # "BaseClass:id", the same for an STI subclass and for the type a
        # polymorphic column stores; nil for an object with no id.
        def ref(object)
          return nil if object.nil? || !object.respond_to?(:id)

          id = object.id
          id.nil? ? nil : "#{base_name(object.class)}:#{id}"
        end

        # A committed membership row: notes the roles it lost, forgets
        # those it holds again, and clears the request's role reads.
        def committed(record)
          watch = @watch
          noted = @noted
          return unless watch && noted && Collectors.active?

          note(noted, record, watch)
          Collectors.current_request&.roles&.clear
        rescue StandardError => e
          Collectors.warn_once(e)
        end

        # Records an allow after a revocation whose freshly read roles still
        # held a revoked role (`roles` those names), under coverage.
        def still_held(stamp, roles)
          return unless Collectors.active?

          @store&.record(RevokedRoleRead.new(entry_point: stamp.entry_point, policy: stamp.policy, rule: stamp.rule,
                                             resource: stamp.resource, roles: roles))
        end

        private

        def note(noted, record, watch)
          before, after = roles_around(record, watch)
          removed = before - after
          user = row_ref(record, watch.member)
          tenant = row_ref(record, watch.within)
          return unless user && tenant && (removed.any? || noted[user]&.key?(tenant))

          noted.update(user, tenant, removed: removed, held: after)
        end

        def unwatched(reason)
          @store&.record(RevocationsUnwatched.new(reason: reason))
          nil
        end

        def warn_load(name, error)
          return if @warned

          @warned = true
          unwatched("the membership class #{name} did not load (#{error.class}), so the revocations collector " \
                    "watched no membership")
          Kernel.warn("hallmark: revocations not watched: #{name} did not load: #{error.message}")
        end

        def reset_per_example
          return unless defined?(::ActiveRecord::TestFixtures)

          fixtures = ::ActiveRecord::TestFixtures
          fixtures.prepend(FixtureReset) unless fixtures.ancestors.include?(FixtureReset)
        end

        # The role names a row held before its last save and holds now. A
        # destroyed row holds none; with `soft_delete:`, a deleted row holds
        # none either, so setting the attribute revokes every role and
        # clearing it grants them again.
        def roles_around(record, watch)
          attribute = watch.roles.to_s
          stored = record.has_attribute?(attribute)
          now = stored ? record.read_attribute(attribute) : record.public_send(attribute)
          gone = record.destroyed?
          before = names(gone || !stored ? now : before_save(record, attribute, now), watch.role_names)
          after = gone ? [] : names(now, watch.role_names)
          column = watch.soft_delete&.to_s
          column ? ended(record, column, before, after) : [before, after]
        end

        # Neither side holds roles where the soft-delete attribute is set.
        def ended(record, column, before, after)
          now = record.read_attribute(column)
          [before_save(record, column, now).nil? ? before : [], now.nil? ? after : []]
        end

        # An attribute's value before the last save, `now` when it did not change.
        def before_save(record, attribute, now)
          record.saved_change_to_attribute?(attribute) ? record.attribute_before_last_save(attribute) : now
        end

        def names(value, role_names)
          values = Array(value).flat_map { |each| role_names ? Array(role_names.call(each)) : [each] }
          values.compact.map(&:to_s).uniq.sort
        end

        # The reference a membership's association names, from its foreign
        # key (and type, when polymorphic) without loading it; through the
        # reader only when the name is no `belongs_to`.
        def row_ref(record, name)
          reflection = record.class.reflect_on_association(name)
          return ref(record.public_send(name)) unless reflection&.belongs_to?

          id = record.read_attribute(reflection.foreign_key)
          return nil if id.nil?

          type = reflection.polymorphic? ? record.read_attribute(reflection.foreign_type) : base_name(reflection.klass)
          type ? "#{type}:#{id}" : nil
        end

        # Read once per class: `ref` runs on every allow while pairs are noted.
        def base_name(klass)
          names = @base_names ||= {}.compare_by_identity
          names[klass] ||= (klass.respond_to?(:base_class) ? klass.base_class : klass).name.to_s
        end
      end
    end
  end
end
