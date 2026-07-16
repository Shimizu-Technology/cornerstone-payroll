# frozen_string_literal: true

class InvoiceNumberAllocator
  def self.call(billing_profile:, invoice_date:)
    new(billing_profile: billing_profile, invoice_date: invoice_date).call
  end

  def initialize(billing_profile:, invoice_date:)
    @billing_profile = billing_profile
    @invoice_date = Date.parse(invoice_date.to_s)
  end

  def call
    billing_profile.with_lock do
      sequence = InvoiceNumberSequence.find_or_initialize_by(
        invoice_billing_profile: billing_profile,
        sequence_year: invoice_date.year
      )
      sequence.last_number = existing_count_for_year if sequence.new_record?

      loop do
        sequence.last_number += 1
        candidate = format_number(sequence.last_number)
        next if Invoice.exists?(invoice_billing_profile: billing_profile, invoice_number: candidate)

        sequence.save!
        return candidate
      end
    end
  end

  private

  attr_reader :billing_profile, :invoice_date

  def existing_count_for_year
    Invoice.where(
      invoice_billing_profile: billing_profile,
      invoice_date: invoice_date.beginning_of_year..invoice_date.end_of_year
    ).count
  end

  def format_number(number)
    prefix = billing_profile.invoice_prefix.presence || "INV"
    "#{prefix}-#{invoice_date.year}-#{number.to_s.rjust(4, '0')}"
  end
end
