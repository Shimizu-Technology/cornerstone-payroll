# frozen_string_literal: true

class DeductionType < ApplicationRecord
  belongs_to :company
  has_many :employee_deductions, dependent: :destroy
  has_many :employees, through: :employee_deductions

  validates :name, presence: true
  validates :name, uniqueness: { scope: :company_id }
  validates :category, inclusion: { in: %w[pre_tax post_tax] }

  scope :active, -> { where(active: true) }
  scope :pre_tax, -> { where(category: "pre_tax") }
  scope :post_tax, -> { where(category: "post_tax") }

  def pre_tax?
    category == "pre_tax"
  end

  def post_tax?
    category == "post_tax"
  end
end
