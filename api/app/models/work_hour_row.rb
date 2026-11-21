# frozen_string_literal: true

# One Work Hours v1 feed row: a Tax user's hours for one date, client,
# category, task, period and approval state. Never holds pay data.
class WorkHourRow < ApplicationRecord
  APPROVAL_STATES = %w[approved clock pending].freeze

  belongs_to :organization
  belongs_to :work_hour_import

  validates :approval_state, inclusion: { in: APPROVAL_STATES }

  def pending?
    approval_state == "pending"
  end

  def internal?
    system_kind == "internal"
  end
end
