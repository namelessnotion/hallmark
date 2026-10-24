# frozen_string_literal: true

module Types
  # `authorize :ability` on a type, checked by authorization.ok?
  class BaseObject < GraphQL::Schema::Object
    field_class Types::BaseField

    def self.authorize(*abilities)
      @authorize = abilities if abilities.any?
      @authorize || (superclass.respond_to?(:authorize) ? superclass.authorize : nil)
    end

    def self.authorization
      @authorization ||= ObjectAuthorization.new(authorize)
    end

    def self.authorized?(object, context)
      authorization.ok?(object, context[:current_user])
    end
  end
end
