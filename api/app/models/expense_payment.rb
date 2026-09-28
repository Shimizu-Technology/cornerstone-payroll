# frozen_string_literal: true

class ExpensePayment < ApplicationRecord
  METHODS = %w[cash check ach card wire other].freeze

  belongs_to :organization
  belongs_to :expense
  belongs_to :recorded_by, class_name: "User", optional: true
  belongs_to :reversed_by, class_name: "User", optional: true

  validates :amount, numericality: { greater_than: 0 }
  validates :paid_on, presence: true
  validates :payment_method, inclusion: { in: METHODS }
  validate :expense_belongs_to_organization
  validate :reversal_fields_are_consistent

  scope :active, -> { where(reversed_at: nil) }
  scope :chronological, -> { order(:paid_on, :id) }

  def reversed?
    reversed_at.present?
  end

  private

  def expense_belongs_to_organization
    return if expense.blank? || organization_id.blank? || expense.organization_id == organization_id

    errors.add(:expense, "must belong to the same organization")
  end

  def reversal_fields_are_consistent
    return if reversed_at.blank? && reversed_by_id.blank? && reversal_reason.blank?
    return if reversed_at.present? && reversal_reason.present?

    errors.add(:base, "Reversed payments require a reversal time and reason")
  end
end
