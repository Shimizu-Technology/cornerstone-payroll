# frozen_string_literal: true

class PayrollParallelRunReview < ApplicationRecord
  belongs_to :payroll_go_live_review
  belongs_to :company
  belongs_to :pay_period
  belongs_to :recorded_by, class_name: "User", optional: true

  validates :pay_period_id, uniqueness: true
  validates :source_system, inclusion: { in: %w[quickbooks] }
  validates :result, inclusion: { in: %w[pass fail] }
  validates :source_employee_count, :cornerstone_employee_count,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :source_gross_pay, :source_net_pay, :source_taxes, :source_deductions,
    :cornerstone_gross_pay, :cornerstone_net_pay, :cornerstone_taxes, :cornerstone_deductions,
    numericality: true
  validates :notes, presence: true, length: { maximum: 2_000 }
  validate :company_matches_review_and_period

  def pass?
    result == "pass"
  end

  private

  def company_matches_review_and_period
    return if company.blank? || pay_period.blank? || payroll_go_live_review.blank?

    errors.add(:company, "must match the go-live review") unless company_id == payroll_go_live_review.company_id
    errors.add(:pay_period, "must belong to the successor company") unless pay_period.company_id == company_id
  end
end
