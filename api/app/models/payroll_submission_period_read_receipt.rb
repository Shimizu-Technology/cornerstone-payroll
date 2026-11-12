# frozen_string_literal: true

class PayrollSubmissionPeriodReadReceipt < ApplicationRecord
  belongs_to :payroll_submission_period
  belongs_to :user
  validates :seen_at, presence: true
  validates :last_seen_event_id, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
