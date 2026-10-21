# typed: true
# frozen_string_literal: true

# The one file in lib/ at `typed: true` rather than strict: the hooks
# graphql-ruby calls for every field and every object forward their
# arguments with `(...)`, the only forwarding that does not pack the
# keywords into a new Hash on each call (about 100 ns and one object per
# call, sampled or not; `rake bench`), and Sorbet cannot sign a method that
# takes `...`. Sorbet still checks the bodies; the other hooks' signatures
# are in the RBI.
module Hallmark
  module Collectors
    module GraphqlHook
      # Given to `trace_with` (graphql-ruby 2.x). Each hook does one
      # fiber-local read unless a sampled multiplex is running.
      module Trace
        def execute_multiplex(multiplex:)
          return super unless Collectors.active?

          GraphqlHook.within_multiplex(multiplex) { super }
        end

        def execute_query(query:)
          return super unless (registry = Thread.current[REGISTRY])

          scope = registry.scope(query)
          TenantCheck.compare(scope)
          GraphqlHook.within(scope.outside) { super }
        end

        def execute_query_lazy(query:, multiplex:)
          return super unless (registry = Thread.current[REGISTRY])

          first = query || multiplex&.queries&.first
          return super unless first

          GraphqlHook.within(registry.scope(first).lazy) { super }
        end

        def execute_field(...)
          return super unless (registry = Thread.current[REGISTRY])

          previous = Thread.current[FRAME]
          Thread.current[FRAME] = registry.field || registry.field_frame(...)
          begin
            super
          ensure
            Thread.current[FRAME] = previous
          end
        end

        def execute_field_lazy(...)
          return super unless (registry = Thread.current[REGISTRY])

          previous = Thread.current[FRAME]
          Thread.current[FRAME] = registry.lazy_frame(...)
          begin
            super
          ensure
            Thread.current[FRAME] = previous
          end
        end

        def authorized(...)
          return super unless (registry = Thread.current[REGISTRY]) && (check = registry.type_check(...))

          begin
            GraphqlHook.finish(check, super)
          rescue StandardError => e
            GraphqlHook.failed(check, e)
            Kernel.raise
          ensure
            GraphqlHook.restore(check)
          end
        end

        def authorized_lazy(...)
          return super unless (registry = Thread.current[REGISTRY]) && (check = registry.type_check(...))

          begin
            GraphqlHook.finish(check, super)
          rescue StandardError => e
            GraphqlHook.failed(check, e)
            Kernel.raise
          ensure
            GraphqlHook.restore(check)
          end
        end
      end
    end
  end
end
