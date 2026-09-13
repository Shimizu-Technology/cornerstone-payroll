# frozen_string_literal: true

class PayrollFilingEvent < ApplicationRecord
  EVENT_TYPES = %w[submitted resubmitted accepted accepted_with_errors rejected correction_needed].freeze

  belongs_to :payroll_filing_record, inverse_of: :events
  belongs_to :company
  belongs_to :recorded_by, class_name: "User"
  belongs_to :evidence_document, class_name: "ClientDocument"

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :to_status, inclusion: { in: PayrollFilingRecord::STATUSES }
  validates :from_status, inclusion: { in: PayrollFilingRecord::STATUSES }, allow_nil: true
  validates :occurred_at, :reference_number, :preparer_name, :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: { scope: :company_id }
  validates :source_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :tenant_consistency
  validate :occurred_at_is_not_in_the_future

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def tenant_consistency
    return if company.blank?

    errors.add(:payroll_filing_record, "must belong to the company") if payroll_filing_record&.company_id != company_id
    errors.add(:evidence_document, "must belong to the company") if evidence_document&.company_id != company_id
    errors.add(:recorded_by, "must belong to the company's organization") if recorded_by&.organization_id != company.organization_id
  end

  def occurred_at_is_not_in_the_future
    return if occurred_at.blank? || occurred_at <= Time.current + 5.minutes

    errors.add(:occurred_at, "cannot be in the future")
  end

  def prevent_mutation
    errors.add(:base, "Filing evidence history is append-only")
    throw :abort
  end
end
