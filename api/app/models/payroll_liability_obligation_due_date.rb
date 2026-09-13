# frozen_string_literal: true

class PayrollLiabilityObligationDueDate < ApplicationRecord
  belongs_to :company
  belongs_to :pay_period
  belongs_to :updated_by, class_name: "User", optional: true

  validates :authority, :due_date, presence: true
  validates :authority, uniqueness: { scope: :pay_period_id }
  validate :company_context_matches
  validate :updated_by_context_matches

  private

  def company_context_matches
    return if company.blank? || pay_period.blank? || company_id == pay_period.company_id

    errors.add(:company, "must match the pay period company")
  end

  def updated_by_context_matches
    return if company.blank? || updated_by.blank? || updated_by.organization_id == company.organization_id

    errors.add(:updated_by, "must belong to the due date company's organization")
  end
end
