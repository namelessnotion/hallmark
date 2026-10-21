# typed: strict
# frozen_string_literal: true

require "openssl"

module Hallmark
  # Who and what a stamp was first seen with in a process, for an operator
  # tracing a shadow or sampled finding back to a request (docs/adr/0004).
  # The request thread captures plain references ("User:42"); the stamp
  # store's flusher hashes them with the environment's key (HMAC-SHA256,
  # hex) before anything is written, and only for a stamp new to the
  # process. An example is never part of a stamp's key, so it changes no
  # deduplication or inference. Fields are nil when the object has no id.
  Example = Struct.new(:user, :record, :tenant, keyword_init: true) do
    # "Class:id" for an object with an id, else nil.
    def self.ref(object)
      return nil unless object.respond_to?(:id)

      id = object.id
      id.nil? ? nil : "#{object.class.name}:#{id}"
    end

    # The same example with each reference replaced by its digest under `key`.
    def hashed(key)
      Example.new(**to_h.transform_values { |ref| ref && OpenSSL::HMAC.hexdigest("SHA256", key, ref.to_s) })
    end

    def to_json_object = to_h.transform_keys(&:to_s)
  end
end
