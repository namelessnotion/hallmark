# frozen_string_literal: true

# Action Policy scopes: the default, a named one, one inherited, and a
# params filter, which lists nothing.
class BasePolicy < ActionPolicy::Base
  authorize :organization

  scope_for :data, :mine do |items|
    items.where(user: user)
  end
end

class DocPolicy < BasePolicy
  relation_scope do |relation|
    relation.where(organization: organization).published
  end

  relation_scope(:own) { |docs| user.docs }

  params_filter do |params|
    params.permit(:title)
  end

  scope_for :action_controller_params do |params|
    params.permit(:body)
  end
end
