# frozen_string_literal: true

class HistoricalPaycheckAdjustment < ApplicationRecord
  KINDS = %w[correction void reversal].freeze
  MONEY_FIELDS = %i[
    gross_pay adjusted_gross pretax_deductions employee_taxes federal_income_tax
    social_security_tax medicare_tax after_tax_deductions net_pay employer_taxes
    employer_contributions total_payroll_cost
  ].freeze
  BREAKDOWN_TOTALS = {
    pretax_deduction_breakdown: :pretax_deductions,
    after_tax_deduction_breakdown: :after_tax_deductions,
    employee_tax_breakdown: :employee_taxes,
    employer_tax_breakdown: :employer_taxes,
    employer_contribution_breakdown: :employer_contributions
  }.freeze

  belongs_to :company
  belongs_to :historical_paycheck
  belongs_to :reverses_adjustment, class_name: "HistoricalPaycheckAdjustment", optional: true
  belongs_to :created_by, class_name: "User"
  has_one :reversal, class_name: "HistoricalPaycheckAdjustment",
                     foreign_key: :reverses_adjustment_id, inverse_of: :reverses_adjustment,
                     dependent: :restrict_with_error
  has_many :events, class_name: "HistoricalPaycheckAdjustmentEvent", dependent: :restrict_with_error

  validates :kind, inclusion: { in: KINDS }
  validates :effective_pay_date, :filing_year, :filing_quarter, :reason, :idempotency_key, presence: true
  validates :reason, length: { maximum: 2_000 }
  validates :external_reference, :idempotency_key, length: { maximum: 255 }
  validates :filing_year, inclusion: { in: 2000..2200 }
  validates :filing_quarter, inclusion: { in: 1..4 }
  validates :idempotency_key, uniqueness: { scope: :company_id }
  validate :tenant_and_source_are_consistent
  validate :filing_period_matches_effective_date
  validate :effective_date_matches_source_coverage
  validate :component_totals_reconcile
  validate :breakdown_entries_are_valid
  validate :reversal_relationship_is_valid

  before_update :prevent_change
  before_destroy :prevent_change

  scope :chronological, -> { order(:effective_pay_date, :created_at, :id) }

  def filing_review_state
    chronological_events.reduce("unreviewed") do |state, event|
      case event.event_type
      when "filing_reviewed_no_amendment" then "no_amendment_required"
      when "filing_amendment_required" then "amendment_required"
      when "filing_amendment_filed_external" then "amendment_filed_external"
      when "filing_review_reopened" then "unreviewed"
      else state
      end
    end
  end

  def filing_reviewed?
    filing_review_state != "unreviewed"
  end

  def downstream_impact_acknowledged?
    if events.loaded?
      events.any? { |event| event.event_type == "downstream_impact_acknowledged" }
    else
      events.where(event_type: "downstream_impact_acknowledged").exists?
    end
  end

  def chronological_events
    if events.loaded?
      events.sort_by { |event| [ event.created_at, event.id ] }
    else
      events.order(:created_at, :id).to_a
    end
  end

  private

  def tenant_and_source_are_consistent
    errors.add(:company, "must match the historical paycheck") if historical_paycheck && historical_paycheck.company_id != company_id
    errors.add(:historical_paycheck, "must come from locked history") if historical_paycheck && !historical_paycheck.historical_import_batch.locked?
    errors.add(:historical_paycheck, "must be linked to an employee") if historical_paycheck && historical_paycheck.employee_id.blank?
    errors.add(:created_by, "must belong to the same organization") if created_by && company && created_by.organization_id != company.organization_id
  end

  def filing_period_matches_effective_date
    return if effective_pay_date.blank?

    errors.add(:filing_year, "must match the effective pay date") if filing_year != effective_pay_date.year
    expected_quarter = ((effective_pay_date.month - 1) / 3) + 1
    errors.add(:filing_quarter, "must match the effective pay date") if filing_quarter != expected_quarter
  end

  def effective_date_matches_source_coverage
    return if effective_pay_date.blank? || historical_paycheck.blank?

    if historical_paycheck.reconciliation_status == "opening_summary"
      return if effective_pay_date.between?(historical_paycheck.period_start, historical_paycheck.pay_date)

      errors.add(:effective_pay_date, "must be within the opening-summary coverage")
    elsif effective_pay_date != historical_paycheck.pay_date
      errors.add(:effective_pay_date, "must match the original paycheck pay date")
    end
  end

  def component_totals_reconcile
    BREAKDOWN_TOTALS.each do |breakdown_field, total_field|
      entries = Array(public_send(breakdown_field))
      expected = public_send(total_field).to_d.round(2)
      actual = entries.sum(0.to_d) do |entry|
        value = entry.respond_to?(:to_h) ? entry.to_h.with_indifferent_access : {}
        BigDecimal(value[:amount].to_s, exception: false) || 0.to_d
      end.round(2)
      next if actual == expected

      errors.add(breakdown_field, "must total #{expected.to_s('F')}")
    end
  end

  def breakdown_entries_are_valid
    HistoricalPayroll::Ledger::BREAKDOWN_FIELDS.each do |field|
      Array(public_send(field)).each_with_index do |entry, index|
        value = entry.respond_to?(:to_h) ? entry.to_h.with_indifferent_access : {}
        label = value[:label].to_s.strip
        amount = BigDecimal(value[:amount].to_s, exception: false)
        errors.add(field, "entry #{index + 1} requires a label") if label.blank?
        errors.add(field, "entry #{index + 1} label is too long") if label.length > 120
        errors.add(field, "entry #{index + 1} requires a numeric amount") if amount.nil?
      end
    end
  end

  def reversal_relationship_is_valid
    if kind == "reversal" && reverses_adjustment.blank?
      errors.add(:reverses_adjustment, "is required for a reversal")
    elsif kind != "reversal" && reverses_adjustment.present?
      errors.add(:reverses_adjustment, "is only allowed for a reversal")
    end
    return if reverses_adjustment.blank?

    errors.add(:reverses_adjustment, "cannot itself be a reversal") if reverses_adjustment.kind == "reversal"
    errors.add(:reverses_adjustment, "must belong to the same paycheck") if reverses_adjustment.historical_paycheck_id != historical_paycheck_id
    errors.add(:reverses_adjustment, "must belong to the same client") if reverses_adjustment.company_id != company_id
  end

  def prevent_change
    errors.add(:base, "Historical paycheck adjustments are append-only")
    throw(:abort)
  end
end
