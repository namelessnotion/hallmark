# frozen_string_literal: true

module Types
  # The app's default field class: checks the field's `authorize:` option.
  class BaseField < GraphQL::Schema::Field
    def authorized?(object, args, ctx)
      field_authorized?(object, ctx) && super
    end
  end
end
