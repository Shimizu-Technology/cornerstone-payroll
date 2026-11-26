# frozen_string_literal: true

# Whether a native paycheck paid on or before an applied opening balance's
# through date is its own payment (distinct) or the same payment the import
# already holds (duplicate_of_imported). Recorded once per paycheck and
# import; see PayrollBridgeOverlap. Append-only.
class PayrollItemBridgeOverlapDisposition < ApplicationRecord
  DISTINCT = "distinct"
  DUPLICATE = "duplicate_of_imported"
  DECISIONS = [ DISTINCT, DUPLICATE ].freeze
  SOURCES = %w[payment_evidence staff_review].freeze

  belongs_to :company
  belongs_to :payroll_item
  belongs_to :historical_import_batch
  belongs_to :historical_paycheck, optional: true
  belongs_to :created_by, class_name: "User"

  validates :decision, inclusion: { in: DECISIONS }
  validates :source, inclusion: { in: SOURCES }
  validates :reason, presence: true
  validates :evidence_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :payroll_item_id, uniqueness: { scope: :historical_import_batch_id }
  validate :duplicate_names_an_imported_paycheck
  validate :records_match_the_company

  before_update { raise ActiveRecord::ReadOnlyRecord, "Bridge overlap dispositions are append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "Bridge overlap dispositions are append-only" }

  scope :distinct_payments, -> { where(decision: DISTINCT) }
  scope :duplicates, -> { where(decision: DUPLICATE) }

  def distinct? = decision == DISTINCT
  def duplicate? = decision == DUPLICATE

  private

  def duplicate_names_an_imported_paycheck
    if duplicate?
      errors.add(:historical_paycheck, "is required for a duplicate") unless historical_paycheck
      if historical_paycheck && historical_paycheck.historical_import_batch_id != historical_import_batch_id
        errors.add(:historical_paycheck, "must come from the same import")
      end
    elsif historical_paycheck_id
      errors.add(:historical_paycheck, "is only recorded for a duplicate")
    end
  end

  def records_match_the_company
    errors.add(:payroll_item, "must belong to the same client") if payroll_item && payroll_item.company_id != company_id
    errors.add(:historical_import_batch, "must belong to the same client") if historical_import_batch && historical_import_batch.company_id != company_id
  end
end
