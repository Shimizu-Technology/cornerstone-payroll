# frozen_string_literal: true

class PayrollFilingRecord < ApplicationRecord
  QUARTERLY_TYPES = %w[form_500_payment w1 swica federal_941].freeze
  ANNUAL_TYPES = %w[w2_gu_w3_ss form_1099_nec].freeze
  FILING_TYPES = (QUARTERLY_TYPES + ANNUAL_TYPES).freeze
  STATUSES = %w[submitted accepted accepted_with_errors rejected needs_correction].freeze

  belongs_to :company
  has_many :events,
           -> { order(:occurred_at, :id) },
           class_name: "PayrollFilingEvent",
           dependent: :restrict_with_error,
           inverse_of: :payroll_filing_record

  validates :filing_type, inclusion: { in: FILING_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :tax_year, numericality: { only_integer: true, greater_than_or_equal_to: 2000, less_than_or_equal_to: 2200 }
  validates :submitted_at, :confirmation_number, presence: true
  validates :source_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :filing_type, uniqueness: { scope: %i[company_id tax_year quarter] }
  validate :quarter_matches_filing_type

  def annual?
    filing_type.in?(ANNUAL_TYPES)
  end

  def display_name
    {
      "form_500_payment" => "Form 500 deposit",
      "w1" => "Guam W-1",
      "swica" => "SWICA / SW-2",
      "federal_941" => "Federal Form 941 with Schedule B",
      "w2_gu_w3_ss" => "W-2GU / W-3SS wage submission",
      "form_1099_nec" => "1099-NEC / 1096 information return"
    }.fetch(filing_type)
  end

  private

  def quarter_matches_filing_type
    if annual? && quarter.present?
      errors.add(:quarter, "must be blank for annual filings")
    elsif !annual? && !quarter.in?(1..4)
      errors.add(:quarter, "must be 1, 2, 3, or 4 for quarterly filings")
    end
  end
end
