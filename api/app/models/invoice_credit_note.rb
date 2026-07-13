# frozen_string_literal: true

class InvoiceCreditNote < ApplicationRecord
  STATUSES = %w[issued voided].freeze

  belongs_to :organization
  belongs_to :invoice
  belongs_to :issued_by, class_name: "User", optional: true
  belongs_to :voided_by, class_name: "User", optional: true

  validates :credit_number, :issue_date, :reason, presence: true
  validates :credit_number, uniqueness: { scope: :organization_id }
  validates :total_amount, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validate :invoice_must_belong_to_organization
  validate :currency_must_match_invoice

  scope :issued, -> { where(status: "issued") }
  scope :chronological, -> { order(:issue_date, :id) }

  def voided?
    status == "voided"
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
end
