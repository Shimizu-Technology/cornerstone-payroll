# frozen_string_literal: true

class PayrollFieldDefinition < ApplicationRecord
  KINDS = %w[addition deduction employer_contribution].freeze
  TAX_TREATMENTS = %w[
    taxable_addition
    non_taxable_addition
    pre_tax_deduction
    post_tax_deduction
    employer_contribution
  ].freeze
  CATEGORIES = %w[
    loan retirement insurance rent allotment reimbursement
    garnishment child_support phone benefit other
  ].freeze
  AMOUNT_TYPES = %w[manual fixed percentage].freeze
  REPORTING_GROUPS = PayrollReportingGroups::GROUPS

  belongs_to :company
  belongs_to :owner_employee, class_name: "Employee", optional: true
  has_many :employee_payroll_fields, dependent: :destroy
  has_many :employees, through: :employee_payroll_fields
  has_many :payroll_item_field_entries, dependent: :nullify

  validates :name, presence: true, uniqueness: { scope: [ :company_id, :owner_employee_id ] }
  validates :kind, inclusion: { in: KINDS }
  validates :tax_treatment, inclusion: { in: TAX_TREATMENTS }
  validates :category, inclusion: { in: CATEGORIES }
  validates :amount_type, inclusion: { in: AMOUNT_TYPES }
  validates :reporting_group, inclusion: { in: REPORTING_GROUPS }, allow_nil: true
  validates :default_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :default_percentage, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :kind_matches_tax_treatment
  validate :owner_belongs_to_company

  scope :active, -> { where(active: true) }
  scope :client_wide, -> { where(owner_employee_id: nil) }
  scope :visible_in_payroll_grid, -> { where(show_in_payroll_grid: true) }
  scope :ordered, -> { order(:sort_order, :name) }

  before_validation :normalize_blank_amounts

  def addition?
    kind == "addition"
  end

  def deduction?
    kind == "deduction"
  end

  def employer_contribution?
    kind == "employer_contribution"
  end

  def employee_paid?
    deduction?
  end

  def employer_paid?
    employer_contribution?
  end

  def employee_only?
    owner_employee_id.present?
  end

  private

  def normalize_blank_amounts
    self.category = "other" if category.blank?
    self.amount_type = "fixed" if amount_type.blank?
    self.default_amount = nil if default_amount.to_s.blank?
    self.default_percentage = nil if default_percentage.to_s.blank?
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

  def owner_belongs_to_company
    return if owner_employee.blank? || owner_employee.company_id == company_id

    errors.add(:owner_employee, "must belong to the same client")
  end
end
