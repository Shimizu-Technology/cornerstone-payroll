# frozen_string_literal: true

class PayrollItemEarning < ApplicationRecord
  CATEGORIES = %w[regular overtime holiday pto salary bonus tips reimbursement non_taxable contract_fee other].freeze

  belongs_to :payroll_item

  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :label, presence: true
  validates :amount, presence: true, numericality: true
  validates :hours, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :label, uniqueness: { scope: [:payroll_item_id, :category] }
end
