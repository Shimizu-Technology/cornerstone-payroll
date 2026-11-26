# frozen_string_literal: true

class Form500Filing < ApplicationRecord
  belongs_to :company
  belongs_to :pay_period
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  STATUSES = %w[prepared paid filed exception].freeze

  validates :pay_period_id, uniqueness: true
  validates :fields, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :payment_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :company_matches_pay_period

  private

  def company_matches_pay_period
    return if pay_period.nil? || company_id == pay_period.company_id

    errors.add(:company, "must match the pay period's company")
  end
end
