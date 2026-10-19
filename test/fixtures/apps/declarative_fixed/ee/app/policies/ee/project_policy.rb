# frozen_string_literal: true

module EE
  module ProjectPolicy
    extend ActiveSupport::Concern

    prepended do
      with_scope :subject
      condition(:ip_restricted) { !::IpRestriction.allows?(@subject) }

      rule { ip_restricted & ~admin }.prevent_all
    end
  end
end
