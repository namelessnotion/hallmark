# frozen_string_literal: true

# A schedule's abilities are its project's.
class SchedulePolicy < BasePolicy
  delegate { @subject.project }
end
