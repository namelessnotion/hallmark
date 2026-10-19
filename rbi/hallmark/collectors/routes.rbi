# typed: strict

module Hallmark
  module Collectors
    module Routes
      # `app` is the Rails application
      sig { params(app: T.untyped, store: T.nilable(StampStore)).void }
      def self.record(app, store = Collectors.store); end

      sig { params(defaults: T::Hash[Symbol, T.untyped]).returns(T.nilable(String)) }
      def self.entry_point(defaults); end
    end
  end
end
