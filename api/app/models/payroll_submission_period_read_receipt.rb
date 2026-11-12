# frozen_string_literal: true

class PayrollSubmissionPeriodReadReceipt < ApplicationRecord
  belongs_to :payroll_submission_period
  belongs_to :user
  validates :seen_at, presence: true
end
