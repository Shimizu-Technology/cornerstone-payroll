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
  validate :demo_company_records_preparation_only

  private

  # A demo company prepares Form 500 like a live client, but nothing is
  # ever filed or paid, so it cannot record either outcome.
  def company_matches_pay_period
    return if pay_period.nil? || company_id == pay_period.company_id

    errors.add(:company, "must match the pay period's company")
  end

  # The pay period's company decides, so a mismatched company_id can't dodge the rule.
  def demo_company_records_preparation_only
    return unless pay_period&.company&.demo? || company&.demo?
    return if status.in?(%w[prepared exception]) && payment_date.nil? && payment_amount.nil? &&
      confirmation_number.blank? && !receipt_attached

    errors.add(:base, Company::DEMO_UNAVAILABLE_MESSAGE)
  end
end
