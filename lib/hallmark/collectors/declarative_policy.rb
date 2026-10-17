# typed: strict
# frozen_string_literal: true

module Hallmark
  module Collectors
    # DeclarativePolicy has no instrumentation, so this prepends `allowed?`
    # on DeclarativePolicy::Base, which `can?` and `Ability.allowed?` reach.
    # The library has no enforcing call of its own, so every decision counts
    # as enforced, including checks a view makes only to render a link.
    module DeclarativePolicyHook
      # Prepended on DeclarativePolicy::Base. `allowed?` with several
      # abilities stops at the first that fails, as the library does.
      module Allowed
        def allowed?(*abilities)
          return super unless Collectors.active?
          return abilities.all? { |ability| allowed?(ability) } if abilities.size > 1
          return super if abilities.empty?

          Collectors.observe(policy: self, rule: abilities.fetch(0), record: subject, enforced: true) { super }
        end
      end

      def self.install
        return if @installed

        @installed = true
        ::DeclarativePolicy::Base.prepend(Allowed)
      end
    end
  end
end
