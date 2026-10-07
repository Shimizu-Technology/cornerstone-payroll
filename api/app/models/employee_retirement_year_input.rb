# frozen_string_literal: true

# Append-only evidence, not a payroll transaction. Opening amounts must exclude
# anything already represented in local payroll or applied historical balances.
class EmployeeRetirementYearInput < ApplicationRecord
  WAGE_STATUSES = %w[unknown verified no_prior_employer_wages].freeze
  AMOUNTS = %i[external_traditional_deferrals external_roth_deferrals
    eligible_compensation_before_system employer_additions_before_system non_roth_after_tax_before_system].freeze
  OPENING_AMOUNTS = %i[eligible_compensation_before_system employer_additions_before_system non_roth_after_tax_before_system].freeze
  SNAPSHOT_ATTRIBUTES = %i[tax_year prior_year_wage_status prior_year_fica_wages prior_year_wage_source
    opening_balances_verified source_reference reason historical_retirement_review].concat(AMOUNTS).freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :created_by, class_name: "User", optional: true

  validates :tax_year, inclusion: { in: 2000..2200 }
  validates :prior_year_wage_status, inclusion: { in: WAGE_STATUSES }
  validates(*AMOUNTS, numericality: { greater_than_or_equal_to: 0 })
  validates :prior_year_fica_wages, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :source_reference, :reason, presence: true
  validate :evidence_is_consistent
  validate :tenant_is_consistent
  before_validation :normalize_historical_review_amounts
  validate :historical_review_is_consistent
  attr_accessor :defer_historical_review_validation
  before_update :prevent_mutation
  before_destroy :prevent_mutation

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def snapshot_attributes
    SNAPSHOT_ATTRIBUTES.index_with { |attribute| public_send(attribute) }.merge(year_input_id: id)
  end

  private

  def normalize_historical_review_amounts
    return unless historical_retirement_review.is_a?(Hash) && historical_retirement_review["classifications"].is_a?(Array)

    historical_retirement_review["classifications"].each do |row|
      next unless row.is_a?(Hash)

      amount = BigDecimal(row["amount"].to_s, exception: false)
      row["amount"] = amount.to_s("F") if amount&.finite? && amount >= 0 && amount == amount.round(2)
    end
  end

  def historical_review_is_consistent
    return if historical_retirement_review == {} || defer_historical_review_validation
    return unless employee

    HistoricalRetirementProjection.new(employee: employee, tax_year: tax_year, review: historical_retirement_review).validate_review!
  rescue ArgumentError => e
    errors.add(:historical_retirement_review, e.message)
  end

  def evidence_is_consistent
    if prior_year_wage_status == "unknown"
      errors.add(:prior_year_fica_wages, "must be blank while prior-year wages are unknown") if prior_year_fica_wages.present?
    elsif WAGE_STATUSES.include?(prior_year_wage_status)
      errors.add(:prior_year_fica_wages, "is required for verified wage evidence") if prior_year_fica_wages.nil?
      errors.add(:prior_year_wage_source, "is required for verified wage evidence") if prior_year_wage_source.blank?
      if prior_year_wage_status == "no_prior_employer_wages" && prior_year_fica_wages.to_d != 0
        errors.add(:prior_year_fica_wages, "must be zero when there were no prior employer wages")
      end
    end
    if OPENING_AMOUNTS.any? { |amount| public_send(amount).to_d.positive? } && !opening_balances_verified?
      errors.add(:opening_balances_verified, "must confirm opening amounts exclude saved payroll and applied historical balances")
    end
  end

  def tenant_is_consistent
    errors.add(:company, "must match the employee company") if employee && company_id != employee.company_id
    if created_by && company && created_by.organization_id != company.organization_id && !created_by.super_admin?
      errors.add(:created_by, "must belong to the same organization")
    end
    errors.add(:employee, "must be a W-2 employee") if employee&.contractor?
  end

  def prevent_mutation
    errors.add(:base, "Retirement year input history is append-only; add a corrected entry")
    throw :abort
  end
end
