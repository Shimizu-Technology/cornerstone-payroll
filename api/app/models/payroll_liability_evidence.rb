# frozen_string_literal: true

class PayrollLiabilityEvidence < ApplicationRecord
  belongs_to :company
  belongs_to :payroll_liability_payment, inverse_of: :evidence
  belongs_to :created_by, class_name: "User", optional: true

  validates :storage_key, :filename, :content_type, :sha256, presence: true
  validates :storage_key, uniqueness: true
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }
  validates :sha256, length: { is: 64 }
  validate :context_is_consistent

  def readonly?
    persisted?
  end

  private

  def context_is_consistent
    return if company_id.blank? || payroll_liability_payment.blank?

    errors.add(:company, "must match the payment company") if company_id != payroll_liability_payment.company_id
    if created_by.present? && created_by.organization_id != company.organization_id
      errors.add(:created_by, "must belong to the evidence company's organization")
    end
  end
end
