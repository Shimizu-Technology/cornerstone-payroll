# frozen_string_literal: true

# Reviewed evidence only; committed wages, taxes and allocations remain intact.
class PayrollItemFicaBasisProof < ApplicationRecord
  belongs_to :payroll_item
  belongs_to :company
  belongs_to :created_by, class_name: "User"

  validates :payroll_item_id, uniqueness: true
  validates :review_reference, presence: true, length: { minimum: 10, maximum: 1000 }
  validates :plan_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :tax_year, :evidence, presence: true
  validate do
    errors.add(:company, "must match payroll item") if payroll_item && company_id != payroll_item.company_id
    errors.add(:tax_year, "must match pay date") if payroll_item && tax_year != payroll_item.pay_period.pay_date.year
  end
  before_update { raise ActiveRecord::ReadOnlyRecord, "FICA basis proofs are append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "FICA basis proofs are append-only" }
end
