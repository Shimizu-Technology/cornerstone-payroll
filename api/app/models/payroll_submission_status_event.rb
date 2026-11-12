# frozen_string_literal: true

# Append-only status history both sides see.
class PayrollSubmissionStatusEvent < ApplicationRecord
  belongs_to :company
  belongs_to :period, class_name: "PayrollSubmissionPeriod", foreign_key: :payroll_submission_period_id, inverse_of: :status_events
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :payroll_submission, optional: true
  belongs_to :payroll_submission_draft, optional: true

  validates :event, inclusion: { in: PayrollSubmissionPeriod::EVENTS.keys }
  validates :from_status, :to_status, inclusion: { in: PayrollSubmissionPeriod::STATUSES }
  validates :actor_audience, inclusion: { in: %w[client staff] }

  def readonly?
    persisted? && !destroyed?
  end
end
