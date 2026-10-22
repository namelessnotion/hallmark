# typed: strict

module Hallmark
  class Inference
    private

    sig { returns(T::Array[Unit]) }
    def list_units; end

    sig { returns(T::Array[Unit]) }
    def list_stamp_units; end

    sig do
      params(policy: String, rule: String, resource: String, extracted: T.nilable(Extractor::Extracted),
             stamps: T::Array[Stamp], calls: T::Array[Stamp]).returns(Unit)
    end
    def list_unit(policy, rule, resource, extracted:, stamps: [], calls: []); end

    sig { params(units: T::Array[Unit]).returns(T::Array[Exposure]) }
    def list_exposures(units); end

    sig { params(entry_point: String, resource: String, units: T::Array[Unit]).returns(T.nilable(Exposure)) }
    def list_exposure(entry_point, resource, units); end

    sig { params(units: T::Array[Unit]).returns(Guard) }
    def union(units); end

    sig { params(units: T::Array[Unit]).returns(T::Array[String]) }
    def list_locations(units); end

    sig { params(exposure: Exposure).void }
    def ask_tenants(exposure); end
  end
end
