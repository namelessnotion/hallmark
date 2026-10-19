# typed: strict

module Hallmark
  class FlagModel
    sig { params(resources: T::Array[Mapping::Resource]).void }
    def initialize(resources)
      @resources = T.let(T.unsafe(nil), T::Array[Mapping::Resource])
    end

    sig { returns(T.nilable(String)) }
    def source; end

    private

    sig { params(name: String).returns(String) }
    def holders(name); end

    sig { params(resource: Mapping::Resource).returns(T.nilable(String)) }
    def public_when(resource); end
  end
end
