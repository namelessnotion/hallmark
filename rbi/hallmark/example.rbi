# typed: strict

module Hallmark
  class Example
    # "Class:id" before hashing, a hex digest after
    sig { returns(T.nilable(String)) }
    def user; end

    sig { returns(T.nilable(String)) }
    def record; end

    sig { returns(T.nilable(String)) }
    def tenant; end

    sig { params(user: T.nilable(String), record: T.nilable(String), tenant: T.nilable(String)).void }
    def initialize(user: nil, record: nil, tenant: nil); end

    sig { params(object: T.untyped).returns(T.nilable(String)) }
    def self.ref(object); end

    sig { params(key: String).returns(Example) }
    def hashed(key); end

    sig { returns(T::Hash[String, T.nilable(String)]) }
    def to_json_object; end
  end
end
