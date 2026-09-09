# frozen_string_literal: true

class PayrollFilingResponsibility < ApplicationRecord
  QUARTERLY_FILING_TYPES = %w[form_941 guam_withholding swica].freeze
  ANNUAL_FILING_TYPES = %w[w2_gu].freeze
  FILING_TYPES = (QUARTERLY_FILING_TYPES + ANNUAL_FILING_TYPES).freeze
  RESPONSIBLE_PARTIES = %w[external_provider cornerstone].freeze
  IMPORTED_PAYROLL_INCLUSIONS = %w[included excluded].freeze

  belongs_to :company
  belongs_to :reviewed_by, class_name: "User", optional: true

  validates :tax_year,
            presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 2000, less_than_or_equal_to: 2200 }
  validates :filing_type, inclusion: { in: FILING_TYPES }
  validates :responsible_party, inclusion: { in: RESPONSIBLE_PARTIES }
  validates :imported_payroll_inclusion, inclusion: { in: IMPORTED_PAYROLL_INCLUSIONS }
  validates :reviewed_at, presence: true
  validates :reviewed_by_name, :reviewed_by_email, :reviewed_by_role, presence: true
  validates :notes, length: { maximum: 2_000 }, allow_blank: true
  validates :company_id, uniqueness: { scope: %i[tax_year quarter filing_type] }
  validate :quarter_matches_filing_type

  scope :for_year, ->(year) { where(tax_year: year) }
  scope :for_quarter, ->(quarter) { where(quarter: quarter) }

  def annual?
    filing_type.in?(ANNUAL_FILING_TYPES)
  end

  def quarterly?
    filing_type.in?(QUARTERLY_FILING_TYPES)
  end

  def decision_payload
    {
      id: id,
      filing_type: filing_type,
      tax_year: tax_year,
      quarter: quarter,
      responsible_party: responsible_party,
      imported_payroll_inclusion: imported_payroll_inclusion,
      source_cutoff_date: source_cutoff_date&.iso8601,
      reviewed_at: reviewed_at&.iso8601,
      reviewed_by: {
        id: reviewed_by_id,
        name: reviewed_by_name,
        email: reviewed_by_email,
        role: reviewed_by_role
      },
      notes: notes,
      updated_at: updated_at&.iso8601
    }
  end

  private

  def quarter_matches_filing_type
    if annual? && quarter.present?
      errors.add(:quarter, "must be blank for annual filings")
    elsif quarterly? && !quarter.in?(1..4)
      errors.add(:quarter, "must be 1, 2, 3, or 4 for quarterly filings")
    end
  end
end
