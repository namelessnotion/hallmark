# typed: strict

module Hallmark
  module Collectors
    module Revocations
      class Watch
        # The membership class's name
        sig { returns(String) }
        def membership; end

        sig { returns(Symbol) }
        def member; end

        sig { returns(Symbol) }
        def within; end

        sig { returns(Symbol) }
        def roles; end

        sig { returns(T.nilable(Symbol)) }
        def soft_delete; end

        sig { returns(T.untyped) }
        def role_names; end

        sig do
          params(membership: String, member: Symbol, within: Symbol, roles: Symbol, soft_delete: T.nilable(Symbol),
                 role_names: T.untyped).void
        end
        def initialize(membership:, member:, within:, roles:, soft_delete:, role_names:); end
      end

      class Noted
        sig { void }
        def initialize
          @lock = T.let(T.unsafe(nil), Thread::Mutex)
          @pairs = T.let(T.unsafe(nil), T::Hash[String, T::Hash[String, T::Array[String]]])
        end

        sig { returns(T::Boolean) }
        def empty?; end

        sig { params(user: String).returns(T.nilable(T::Hash[String, T::Array[String]])) }
        def [](user); end

        sig { params(user: String, tenant: String, removed: T::Array[String], held: T::Array[String]).void }
        def update(user, tenant, removed:, held:); end

        sig { void }
        def clear; end

        sig { returns(T::Hash[String, T::Hash[String, T::Array[String]]]) }
        def to_h; end
      end

      # Included into the membership class, an Active Record model
      module Callback
        private

        sig { void }
        def hallmark_revocations_committed; end
      end

      # Prepended on ActiveRecord::TestFixtures
      module FixtureReset
        sig { returns(T.untyped) }
        def before_setup; end
      end

      @store = T.let(nil, T.nilable(StampStore))
      @watch = T.let(nil, T.nilable(Watch))
      @noted = T.let(nil, T.nilable(Noted))
      @warned = T.let(nil, T.nilable(T::Boolean))
      @base_names = T.let(nil, T.nilable(T::Hash[T.untyped, String]))

      class << self
        sig { returns(T.nilable(Noted)) }
        attr_reader :noted

        sig { returns(T.nilable(Watch)) }
        attr_reader :watch

        sig { params(mapping: Mapping, store: StampStore).returns(T.nilable(Noted)) }
        def install(mapping, store); end

        sig { returns(NilClass) }
        def uninstall; end

        sig { void }
        def attach; end

        sig { params(object: T.untyped).returns(T.nilable(String)) }
        def ref(object); end

        # `record` is an Active Record model
        sig { params(record: T.untyped).void }
        def committed(record); end

        sig { params(stamp: Stamp, roles: T::Array[String]).void }
        def still_held(stamp, roles); end

        private

        sig { params(noted: Noted, record: T.untyped, watch: Watch).void }
        def note(noted, record, watch); end

        sig do
          params(record: T.untyped, column: String, before: T::Array[String], after: T::Array[String])
            .returns([T::Array[String], T::Array[String]])
        end
        def ended(record, column, before, after); end

        sig { params(record: T.untyped, attribute: String, now: T.untyped).returns(T.untyped) }
        def before_save(record, attribute, now); end

        sig { params(reason: String).returns(NilClass) }
        def unwatched(reason); end

        sig { params(name: T.nilable(String), error: Exception).void }
        def warn_load(name, error); end

        sig { void }
        def reset_per_example; end

        sig { params(record: T.untyped, watch: Watch).returns([T::Array[String], T::Array[String]]) }
        def roles_around(record, watch); end

        sig { params(value: T.untyped, role_names: T.untyped).returns(T::Array[String]) }
        def names(value, role_names); end

        sig { params(record: T.untyped, name: Symbol).returns(T.nilable(String)) }
        def row_ref(record, name); end

        sig { params(klass: T.untyped).returns(T.nilable(String)) }
        def base_name(klass); end
      end
    end
  end
end
