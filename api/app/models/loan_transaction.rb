# frozen_string_literal: true

class LoanTransaction < ApplicationRecord
  TYPES = %w[payment addition adjustment].freeze
  SOURCES = %w[opening_balance payroll manual].freeze

  belongs_to :employee_loan
  belongs_to :reverses_transaction, class_name: "LoanTransaction", optional: true
  has_one :reversal, class_name: "LoanTransaction", foreign_key: :reverses_transaction_id
  belongs_to :pay_period, optional: true
  belongs_to :payroll_item, optional: true
  belongs_to :recorded_by, class_name: "User", optional: true

  before_validation :initialize_source

  validates :transaction_type, presence: true, inclusion: { in: TYPES }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :balance_before, presence: true, numericality: { greater_than_or_equal_to: 0 }, if: :balance_tracked?
  validates :balance_after, presence: true, numericality: { greater_than_or_equal_to: 0 }, if: :balance_tracked?
  validates :transaction_date, presence: true
  validates :source, presence: true, inclusion: { in: SOURCES }
  validate :balance_shape_matches_loan

  scope :payments, -> { where(transaction_type: "payment") }
  scope :additions, -> { where(transaction_type: "addition") }
  scope :chronological, -> { order(transaction_date: :asc, created_at: :asc) }

  private

  def balance_tracked?
    employee_loan&.balance_tracked? != false
  end

  def balance_shape_matches_loan
    return unless employee_loan&.recurring_no_balance?
    return if balance_before.nil? && balance_after.nil?

    errors.add(:base, "Recurring deduction events do not carry a loan balance")
  end

  def initialize_source
    self.source ||= payroll_item_id.present? ? "payroll" : "manual"
  end
end
