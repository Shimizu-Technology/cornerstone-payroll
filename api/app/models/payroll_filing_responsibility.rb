# frozen_string_literal: true

class PayrollFilingResponsibility < ApplicationRecord
  QUARTERLY_FILING_TYPES = %w[form_941 guam_withholding swica].freeze
  ANNUAL_FILING_TYPES = %w[w2_gu].freeze
  # Information returns are annual, but stay out of the W-2GU annual gate so a
  # 1099 decision never blocks W-2GU readiness.
  INFORMATION_RETURN_FILING_TYPES = %w[form_1099].freeze
  YEAR_END_FILING_TYPES = (ANNUAL_FILING_TYPES + INFORMATION_RETURN_FILING_TYPES).freeze
  FILING_TYPES = (QUARTERLY_FILING_TYPES + YEAR_END_FILING_TYPES).freeze
  # client: the client files its own return. no_filing: this record files no
  # return of this type for the year (for example an inactive duplicate).
  RESPONSIBLE_PARTIES = %w[external_provider cornerstone client no_filing].freeze
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
  validate :prior_provider_through_matches_decision
  validate :party_matches_filing_type

  scope :for_year, ->(year) { where(tax_year: year) }
  scope :for_quarter, ->(quarter) { where(quarter: quarter) }

  def annual?
    filing_type.in?(YEAR_END_FILING_TYPES)
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
      prior_provider_through: prior_provider_through&.iso8601,
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

  # The client files, or no forms, is a year-end answer; quarterly returns
  # are filed by Cornerstone or another provider.
  def party_matches_filing_type
    return unless responsible_party.in?(%w[client no_filing]) && !annual?

    errors.add(:responsible_party, "can be the client or no filing only for W-2GU and 1099 decisions")
  end

  def prior_provider_through_matches_decision
    return if prior_provider_through.blank?

    if !annual? || responsible_party != "cornerstone"
      errors.add(:prior_provider_through, "applies only when Cornerstone files the year-end return")
    elsif tax_year.present? && prior_provider_through.year != tax_year
      errors.add(:prior_provider_through, "must be a date in #{tax_year}")
    end
  end
end
