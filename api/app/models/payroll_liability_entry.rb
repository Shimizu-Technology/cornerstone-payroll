# frozen_string_literal: true

class PayrollLiabilityEntry < ApplicationRecord
  CATEGORIES = %w[
    guam_income_tax_withheld
    social_security_employee
    social_security_employer
    medicare_employee
    medicare_employer
    additional_medicare_employee
    retirement_employee
    roth_retirement_employee
    retirement_employer
    roth_retirement_employer
    insurance_employee
    garnishment
    child_support
    benefit_employee
    benefit_employer
    other_payroll_liability
  ].freeze

  belongs_to :payroll_liability_posting, inverse_of: :entries
  belongs_to :company
  belongs_to :payroll_item, optional: true
  belongs_to :pay_component_tax_rule, optional: true
  has_many :payroll_liability_allocations, dependent: :restrict_with_error

  validates :component_key, :category, :authority, presence: true
  validates :category, inclusion: { in: CATEGORIES }
  validates :amount, numericality: { other_than: 0 }
  validate :company_matches_posting
  validate :payroll_item_matches_posting

  def readonly?
    persisted?
  end

  private

  def company_matches_posting
    return if company_id.blank? || payroll_liability_posting.blank?
    return if company_id == payroll_liability_posting.company_id

    errors.add(:company_id, "must match the liability posting company")
  end

  def payroll_item_matches_posting
    return if payroll_item.blank? || payroll_liability_posting.blank?
    return if payroll_item.pay_period_id == payroll_liability_posting.pay_period_id && payroll_item.company_id == company_id

    errors.add(:payroll_item, "must belong to the posting pay period and company")
  end
end
