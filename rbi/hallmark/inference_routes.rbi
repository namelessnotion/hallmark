# typed: strict

module Hallmark
  class Inference
    private

    sig { returns(T::Array[Exposure]) }
    def route_exposures; end

    sig { returns(T::Array[Exposure]) }
    def grape_exposures; end

    sig do
      params(entry_point: String, authorizations: T::Array[Extractor::Controllers::Authorization],
             checked: T::Boolean).returns(T::Array[Exposure])
    end
    def route_exposures_of(entry_point, authorizations, checked); end

    sig { params(authorization: Extractor::Controllers::Authorization).returns(T.nilable(Unit)) }
    def route_unit(authorization); end

    sig { params(extracted: T.nilable(Extractor::Extracted)).returns(T.nilable(Unit)) }
    def code_unit(extracted); end
  end
end
