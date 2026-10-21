# typed: strict
# frozen_string_literal: true

module Hallmark
  module Collectors
    # An `around_action` that names the entry point for the decisions made
    # inside it, and flags the entry point when it finishes without any
    # authorization call (threat 10). A request a filter halted (a redirect
    # to sign in) or that failed (status 400 or above, or an exception) is
    # not flagged, and neither is one whose decisions are not sampled. A
    # flagged request carries its status and HTTP verb, so Inference can
    # excuse a GET the action body redirected before authorizing when other
    # requests to the entry point did authorize.
    module ControllerHook
      # Included into ActionController::Base and ActionController::API.
      module Around
        private

        def hallmark_entry_point
          return yield unless Collectors.active?

          Collectors.within_entry_point("#{self.class.name}##{action_name}", host: self) do |current|
            yield
            status = response.status
            unless current.checked || current.halted || !current.sampled || status >= 400
              Collectors.unchecked!(current.entry_point_name, status: status, verb: request.request_method)
            end
          end
        end

        def halted_callback_hook(*)
          current = Collectors.current_request
          current.halted = true if current
          super
        end
      end

      # Prepended: the collectors install after Rails eager loads the app's
      # controllers, and a callback added to ActionController::Base then
      # goes to the end of each subclass's chain, after its own filters, so
      # an `authorize` in a `before_action` would run outside the entry point.
      def self.attach(base)
        return if base.include?(Around)

        base.include(Around)
        base.prepend_around_action(:hallmark_entry_point)
      end
    end
  end
end
