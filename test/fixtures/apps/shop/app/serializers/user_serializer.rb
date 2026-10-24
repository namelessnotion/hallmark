# frozen_string_literal: true

# A user, as products nest one. Never loaded.
class UserSerializer < ActiveModel::Serializer
  attributes :id, :name
end
