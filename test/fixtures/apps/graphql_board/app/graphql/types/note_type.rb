# frozen_string_literal: true

module Types
  class NoteType < Types::BaseObject
    reauthorize_scoped_objects(false)

    def self.scope_items(items, context)
      items.where(author: context[:current_user])
    end

    field :body, String, null: false
  end
end
