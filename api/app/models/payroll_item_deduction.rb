# frozen_string_literal: true

class PayrollItemDeduction < ApplicationRecord
  CATEGORIES = %w[pre_tax post_tax employer_contribution].freeze

  belongs_to :payroll_item
  belongs_to :deduction_type

  validates :amount, presence: true, numericality: true
  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :label, presence: true
  validates :deduction_type_id, uniqueness: { scope: :payroll_item_id }

  scope :pre_tax, -> { where(category: "pre_tax") }
  scope :post_tax, -> { where(category: "post_tax") }
  scope :employer_contributions, -> { where(category: "employer_contribution") }

  def pre_tax?
    category == "pre_tax"
  end

  def post_tax?
    category == "post_tax"
  end

  def employer_contribution?
    category == "employer_contribution"
  end
end
