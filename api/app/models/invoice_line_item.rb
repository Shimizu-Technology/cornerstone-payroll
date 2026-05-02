# frozen_string_literal: true

class InvoiceLineItem < ApplicationRecord
  belongs_to :invoice, inverse_of: :line_items

  before_validation :normalize_values
  before_validation :calculate_amount

  validates :description, presence: true
  validates :quantity, numericality: { greater_than_or_equal_to: 0 }
  validates :rate, numericality: { greater_than_or_equal_to: 0 }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  private

  def normalize_values
    self.description = description.to_s.strip
    self.quantity = 0 if quantity.nil?
    self.rate = 0 if rate.nil?
    self.position = 0 if position.nil?
  end

  def calculate_amount
    self.amount = BigDecimal(quantity.to_s) * BigDecimal(rate.to_s)
  end
end
