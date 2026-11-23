# frozen_string_literal: true

class PayrollHistoryReviewItem < ApplicationRecord
  RESOLUTION_CODES = {
    "voided_pay_period" => %w[void_replaced void_reissued],
    "reversed_payroll_item" => %w[reversal_reviewed],
    "legacy_disposition" => [],
    "legacy_basis_gap" => %w[legacy_basis_accepted],
    "imported_history" => %w[imports_reconciled]
  }.freeze
  DETECTION_ACTOR_NAME = "Payroll history detection"
  PROVEN_CODE = "legacy_basis_proven"
  RESOLUTION_FIELDS = %w[resolution_code resolution_reference resolved_by_id resolved_at].freeze

  belongs_to :company
  belongs_to :pay_period, optional: true
  belongs_to :payroll_item, optional: true
  belongs_to :employee, optional: true
  belongs_to :historical_import_batch, optional: true
  belongs_to :resolved_by, class_name: "User", optional: true

  validates :status, inclusion: { in: %w[open resolved] }
  validates :subject_type, inclusion: { in: RESOLUTION_CODES.keys }
  validates :subject_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :resolution_reference, length: { in: 10..1000 }, if: :resolved?
  validates :resolution_code, inclusion: { in: ->(item) { item.storable_resolution_codes } }, if: :resolved?
  validates :resolved_at, presence: true, if: :resolved?
  validates :resolved_by, presence: true, if: -> { resolved? && !system_proven? }
  normalizes :resolution_reference, with: ->(reference) { reference.strip }

  def resolved?
    status == "resolved"
  end

  def system_proven?
    resolution_code == PROVEN_CODE && resolved_by_id.nil?
  end

  def reviewer_name
    system_proven? ? DETECTION_ACTOR_NAME : resolved_by&.name
  end

  def available_resolution_codes
    codes = RESOLUTION_CODES.fetch(subject_type, [])
    # A legacy-wage closure is also the employee's filing acknowledgment.
    subject_type == "legacy_basis_gap" ? codes : codes + [ "other" ]
  end

  def storable_resolution_codes
    subject_type == "legacy_basis_gap" ? available_resolution_codes + [ PROVEN_CODE ] : available_resolution_codes
  end
end
