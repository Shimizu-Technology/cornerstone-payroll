# frozen_string_literal: true

class HistoricalPaycheckFicaBasisProof < ApplicationRecord
  belongs_to :historical_paycheck
  belongs_to :company
  belongs_to :created_by, class_name: "User"

  validates :historical_paycheck_id, uniqueness: true
  validates :review_reference, presence: true, length: { minimum: 10, maximum: 1000 }
  validates :plan_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :tax_year, :evidence, presence: true
  validate do
    errors.add(:company, "must match imported paycheck") if historical_paycheck && company_id != historical_paycheck.company_id
    errors.add(:tax_year, "must match pay date") if historical_paycheck && tax_year != historical_paycheck.pay_date.year
  end
  before_update { raise ActiveRecord::ReadOnlyRecord, "Imported FICA proofs are append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "Imported FICA proofs are append-only" }
end
