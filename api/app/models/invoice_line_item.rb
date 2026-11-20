# frozen_string_literal: true

class InvoiceLineItem < ApplicationRecord
  belongs_to :invoice, inverse_of: :line_items

  before_validation :normalize_values
  before_validation :calculate_amount
  before_update :prevent_issued_invoice_change
  before_destroy :prevent_issued_invoice_change

  validates :line_kind, inclusion: { in: %w[service_fee reimbursement] }
  validates :description, presence: true
  validates :quantity, numericality: { greater_than_or_equal_to: 0 }
  validates :rate, numericality: { greater_than_or_equal_to: 0 }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  validate :supported_precision

  private

  def prevent_issued_invoice_change
    return unless invoice&.issued?

    errors.add(:base, "Issued invoice line items are immutable")
    throw :abort
  end

  def normalize_values
    self.item_name = item_name.to_s.strip
    self.description = description.to_s.strip
    self.quantity = 0 if quantity.nil?
    self.rate = 0 if rate.nil?
    self.position = 0 if position.nil?
  end

  def supported_precision
    %i[quantity rate].each do |field|
      raw = public_send("#{field}_before_type_cast")
      next if raw.nil?

      value = BigDecimal(raw.to_s)
      errors.add(field, "cannot have more than two decimal places") unless value.finite? && value == value.round(2)
    rescue ArgumentError, TypeError
      errors.add(field, "must be a valid number")
    end
  end

  def calculate_amount
    self.amount = (BigDecimal(quantity.to_s) * BigDecimal(rate.to_s)).round(2, :half_up)
    self.reimbursement_review_required = line_kind == "reimbursement" && amount.zero?
  end
end
