# frozen_string_literal: true

class InvoiceNumberSequence < ApplicationRecord
  belongs_to :invoice_billing_profile

  validates :sequence_year, inclusion: { in: 1900..9999 }
  validates :last_number, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :sequence_year, uniqueness: { scope: :invoice_billing_profile_id }
end
