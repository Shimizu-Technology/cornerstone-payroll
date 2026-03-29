# frozen_string_literal: true

class LoanTransaction < ApplicationRecord
  TYPES = %w[payment addition adjustment].freeze

  belongs_to :employee_loan
  belongs_to :pay_period, optional: true
  belongs_to :payroll_item, optional: true

  validates :transaction_type, presence: true, inclusion: { in: TYPES }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :balance_before, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :balance_after, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :transaction_date, presence: true

  scope :payments, -> { where(transaction_type: "payment") }
  scope :additions, -> { where(transaction_type: "addition") }
  scope :chronological, -> { order(transaction_date: :asc, created_at: :asc) }
end
