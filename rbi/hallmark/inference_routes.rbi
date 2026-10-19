# typed: strict

module Hallmark
  class Inference
    private

    sig { params(entry_point: String, resource: String, units: T::Array[Unit]).returns(T::Array[String]) }
    def locations_for(entry_point, resource, units); end

    sig { params(entry_point: String).returns(T.nilable(String)) }
    def entry_site(entry_point); end

    sig { params(entry_point: String, resource: String).returns(T::Array[String]) }
    def check_locations(entry_point, resource); end

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
