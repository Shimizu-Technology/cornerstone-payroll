# frozen_string_literal: true

class InvoiceNumberAllocator
  def self.call(billing_profile:, invoice_date:)
    new(billing_profile: billing_profile, invoice_date: invoice_date).call
  end

  # The number the next issue would take, without reserving it. Another
  # issue can take it first, so screens label it "assigned when issued".
  def self.preview(billing_profile:, invoice_date:)
    new(billing_profile: billing_profile, invoice_date: invoice_date).preview
  end

  def initialize(billing_profile:, invoice_date:)
    @billing_profile = billing_profile
    @invoice_date = Date.parse(invoice_date.to_s)
  end

  def call
    billing_profile.with_lock do
      if billing_profile.numbering_style == "continuing"
        number = billing_profile.next_invoice_number
        number += 1 while continuing_number_taken?(number)
        billing_profile.update!(next_invoice_number: number + 1)
        return billing_profile.format_continuing_number(number)
      end

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

  def preview
    if billing_profile.numbering_style == "continuing"
      number = billing_profile.next_invoice_number
      number += 1 while continuing_number_taken?(number)
      return billing_profile.format_continuing_number(number)
    end

    sequence = InvoiceNumberSequence.find_by(invoice_billing_profile: billing_profile, sequence_year: invoice_date.year)
    number = sequence ? sequence.last_number : existing_count_for_year
    loop do
      number += 1
      candidate = format_number(number)
      return candidate unless Invoice.exists?(invoice_billing_profile: billing_profile, invoice_number: candidate)
    end
  end

  private

  attr_reader :billing_profile, :invoice_date

  # A continuing number is the same number with or without leading zeros:
  # "7055" and "07055" can't both be issued for one sender.
  def continuing_number_taken?(number)
    Invoice.where(invoice_billing_profile: billing_profile)
           .where("invoice_number ~ '^[0-9]+$' AND ltrim(invoice_number, '0') = ?", number.to_s)
           .exists?
  end

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
