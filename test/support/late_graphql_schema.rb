# frozen_string_literal: true

# A schema class defined after the collectors are installed, as Rails
# autoloads one; loading it again reopens it.
module GraphqlShop
  class LateSchema < GraphQL::Schema
    query QueryType unless query
  end
end
