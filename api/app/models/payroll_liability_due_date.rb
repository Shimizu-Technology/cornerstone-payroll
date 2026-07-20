# frozen_string_literal: true

class PayrollLiabilityDueDate < ApplicationRecord
  belongs_to :company
  belongs_to :pay_period
  belongs_to :updated_by, class_name: "User", optional: true

  validates :category, inclusion: { in: PayrollLiabilityEntry::CATEGORIES }
  validates :authority, :due_date, presence: true
  validates :category, uniqueness: { scope: [ :pay_period_id, :authority ] }
  validate :context_matches_pay_period

  private

  def context_matches_pay_period
    return if pay_period.blank? || company_id.blank?

    errors.add(:company, "must match the pay period company") if company_id != pay_period.company_id
    return if pay_period.payroll_liability_postings.joins(:entries)
      .where(payroll_liability_entries: { category:, authority: }).exists?

    errors.add(:base, "must reference a liability category and recipient in the pay period")
  end
end
