# frozen_string_literal: true

class Expense < ApplicationRecord
  belongs_to :organization
  belongs_to :expense_vendor
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true
  has_many :expense_payments, dependent: :restrict_with_error
  has_many :expense_artifacts, dependent: :restrict_with_error
  include FinanceBookOwned

  validates :description, :category, :expense_on, presence: true
  validates :total_amount, numericality: { greater_than: 0 }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validates :source_key, uniqueness: { scope: :finance_book_id }, allow_blank: true
  validate :vendor_belongs_to_organization
  validate :vendor_belongs_to_book
  validate :financial_fields_locked_after_payment, on: :update
  validate :total_has_cent_precision

  scope :recent, -> { order(expense_on: :desc, id: :desc) }
  scope :active, -> { where(voided_at: nil) }

  def amount_paid
    expense_payments.reject(&:reversed?).sum(0.to_d, &:amount)
  end

  def balance_due
    return 0.to_d if voided?

    total_amount - amount_paid
  end

  def payment_status
    return "voided" if voided?
    return "paid" if balance_due.zero?
    return "overdue" if due_on.present? && due_on < Date.current
    return "partial" if amount_paid.positive?

    "open"
  end

  def voided?
    voided_at.present?
  end

  private

  def finance_book_parent
    expense_vendor
  end

  def vendor_belongs_to_book
    return if expense_vendor.blank? || finance_book.blank? || expense_vendor.finance_book_id == finance_book_id

    errors.add(:expense_vendor, "must belong to the same financial book")
  end

  def vendor_belongs_to_organization
    return if expense_vendor.blank? || organization_id.blank? || expense_vendor.organization_id == organization_id

    errors.add(:expense_vendor, "must belong to the same organization")
  end

  def financial_fields_locked_after_payment
    return unless will_save_change_to_expense_vendor_id? || will_save_change_to_total_amount? || will_save_change_to_currency?
    return unless expense_payments.active.exists?

    errors.add(:base, "Reverse recorded payments before changing the vendor, amount, or currency")
  end

  def total_has_cent_precision
    return if total_amount.blank? || total_amount.to_d == total_amount.to_d.round(2)

    errors.add(:total_amount, "must use cents")
  end
end
