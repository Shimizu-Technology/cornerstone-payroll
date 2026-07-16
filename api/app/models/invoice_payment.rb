# frozen_string_literal: true

class InvoicePayment < ApplicationRecord
  METHODS = %w[cash check ach card wire adjustment legacy other].freeze

  belongs_to :organization
  belongs_to :invoice
  belongs_to :recorded_by, class_name: "User", optional: true
  belongs_to :reversed_by, class_name: "User", optional: true

  validates :amount, numericality: { greater_than: 0 }
  validates :received_on, presence: true
  validates :payment_method, inclusion: { in: METHODS }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validate :invoice_must_belong_to_organization
  validate :currency_must_match_invoice
  validate :reversal_fields_are_consistent

  scope :active, -> { where(reversed_at: nil) }
  scope :chronological, -> { order(:received_on, :id) }

  def reversed?
    reversed_at.present?
  end

  private

  def invoice_must_belong_to_organization
    return if invoice.blank? || organization_id.blank? || invoice.organization_id == organization_id

    errors.add(:invoice, "must belong to the same organization")
  end

  def currency_must_match_invoice
    return if invoice.blank? || currency.blank? || currency == invoice.currency

    errors.add(:currency, "must match the invoice currency")
  end

  def reversal_fields_are_consistent
    return if reversed_at.blank? && reversed_by_id.blank? && reversal_reason.blank?
    return if reversed_at.present? && reversal_reason.present?

    errors.add(:base, "Reversed payments require a reversal time and reason")
  end
end
