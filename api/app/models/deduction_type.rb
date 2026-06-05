# frozen_string_literal: true

class DeductionType < ApplicationRecord
  CATEGORIES = %w[pre_tax post_tax employer_contribution].freeze
  SUB_CATEGORIES = %w[
    retirement insurance garnishment loan rent phone benefit
    allotment reimbursement child_support other
  ].freeze
  REPORTING_GROUPS = PayrollReportingGroups::GROUPS

  belongs_to :company
  has_many :employee_deductions, dependent: :destroy
  has_many :employees, through: :employee_deductions
  has_many :payroll_item_deductions, dependent: :restrict_with_error
  has_many :employee_loans, dependent: :nullify

  validates :name, presence: true
  validates :name, uniqueness: { scope: :company_id }
  validates :category, inclusion: { in: CATEGORIES }
  validates :sub_category, inclusion: { in: SUB_CATEGORIES }, allow_nil: true
  validates :reporting_group, inclusion: { in: REPORTING_GROUPS }, allow_nil: true

  before_validation :normalize_reporting_group

  scope :active, -> { where(active: true) }
  scope :pre_tax, -> { where(category: "pre_tax") }
  scope :post_tax, -> { where(category: "post_tax") }
  scope :employer_contribution, -> { where(category: "employer_contribution") }
  scope :check_generating, -> { where(generates_check: true) }
  scope :by_sub_category, ->(sub) { where(sub_category: sub) }

  def pre_tax?
    category == "pre_tax"
  end

  def post_tax?
    category == "post_tax"
  end

  def employer_contribution?
    category == "employer_contribution"
  end

  def loan?
    sub_category == "loan"
  end

  def garnishment?
    sub_category.in?(%w[garnishment child_support])
  end

  private

  def normalize_reporting_group
    self.reporting_group = PayrollReportingGroups.normalize(reporting_group)
  end
end
