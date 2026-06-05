# frozen_string_literal: true

class PayrollItemFieldEntry < ApplicationRecord
  SOURCES = %w[employee_default manual import system].freeze
  REPORTING_GROUPS = PayrollReportingGroups::GROUPS

  belongs_to :payroll_item
  belongs_to :payroll_field_definition, optional: true

  validates :label, presence: true
  validates :kind, inclusion: { in: PayrollFieldDefinition::KINDS }
  validates :tax_treatment, inclusion: { in: PayrollFieldDefinition::TAX_TREATMENTS }
  validates :category, inclusion: { in: PayrollFieldDefinition::CATEGORIES }
  validates :source, inclusion: { in: SOURCES }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :reporting_group, inclusion: { in: REPORTING_GROUPS }, allow_nil: true
  validates :payroll_field_definition_id, uniqueness: { scope: :payroll_item_id }, allow_nil: true
  validate :kind_matches_tax_treatment

  scope :active, -> { where(active: true) }
  scope :employee_paid, -> { where(employee_paid: true) }
  scope :employer_paid, -> { where(employer_paid: true) }
  scope :by_treatment, ->(treatment) { where(tax_treatment: treatment) }

  def taxable_addition?
    tax_treatment == "taxable_addition"
  end

  def non_taxable_addition?
    tax_treatment == "non_taxable_addition"
  end

  def pre_tax_deduction?
    tax_treatment == "pre_tax_deduction"
  end

  def post_tax_deduction?
    tax_treatment == "post_tax_deduction"
  end

  def employer_contribution?
    tax_treatment == "employer_contribution"
  end

  before_validation :normalize_reporting_group

  private

  def normalize_reporting_group
    self.reporting_group = PayrollReportingGroups.normalize(reporting_group)
  end

  def kind_matches_tax_treatment
    valid = case kind
    when "addition"
      tax_treatment.in?(%w[taxable_addition non_taxable_addition])
    when "deduction"
      tax_treatment.in?(%w[pre_tax_deduction post_tax_deduction])
    when "employer_contribution"
      tax_treatment == "employer_contribution"
    else
      false
    end

    errors.add(:tax_treatment, "does not match field type") unless valid
  end
end
