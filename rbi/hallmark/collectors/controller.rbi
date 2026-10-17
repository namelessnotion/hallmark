# typed: strict

module Hallmark
  module Collectors
    module ControllerHook
      # Included into controllers, so these run as controller methods.
      module Around
        # Provided by the controller
        sig { returns(String) }
        def action_name; end

        sig { returns(T::Class[T.anything]) }
        def class; end

        sig { returns(T.untyped) }
        def request; end

        sig { returns(T.untyped) }
        def response; end

        private

        sig { params(blk: T.proc.void).void }
        def hallmark_entry_point(&blk); end

        sig { params(args: T.untyped).void }
        def halted_callback_hook(*args); end
      end

      sig { params(base: T.untyped).void }
      def self.attach(base); end
    end
  end
end
