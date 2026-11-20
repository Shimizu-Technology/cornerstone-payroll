# frozen_string_literal: true

module InvoicePdf
  # Read-only view of an invoice snapshot shared by every renderer. All
  # values come from the snapshot, never from live records, so an issued
  # invoice re-renders with the content it was issued with.
  class InvoiceData
    include ActionView::Helpers::NumberHelper

    DEFAULT_PAYMENT_TEXT = "Please remit payment according to the instructions on this invoice."

    attr_reader :snapshot

    def initialize(snapshot)
      @snapshot = snapshot || {}
    end

    def invoice
      snapshot.fetch("invoice", {}) || {}
    end

    def billing
      snapshot.fetch("billing_profile", {}) || {}
    end

    def recipient
      snapshot.fetch("recipient", {}) || {}
    end

    def lines
      Array(snapshot["line_items"])
    end

    def status
      invoice["status"].to_s
    end

    def draft?
      status == "draft"
    end

    def sample?
      status == "sample"
    end

    # Unissued drafts carry a "DRAFT-<uuid>" placeholder that must never print.
    def display_number
      number = invoice["invoice_number"].to_s
      number.blank? || number.start_with?("DRAFT-") ? "Draft" : number
    end

    def preview_marker
      return "Sample preview, not an invoice" if sample?

      "Draft preview" if draft?
    end

    def sender_name
      billing["legal_name"].presence || billing["name"].to_s
    end

    def sender_address_lines
      split_lines(billing["address"])
    end

    def sender_contact
      [ billing["email"], billing["phone"], billing["website"] ].compact_blank
    end

    def recipient_name
      recipient["name"].to_s
    end

    def recipient_address_lines
      split_lines(recipient["address"])
    end

    def customer_reference
      invoice["customer_reference"].presence
    end

    def terms
      invoice["payment_terms"].to_s.strip.presence
    end

    def notes
      invoice["notes"].to_s.strip.presence
    end

    def footer_note
      billing["footer_note"].to_s.strip.presence
    end

    # The profile's own instructions. The old generic default sentence adds
    # nothing, so it is hidden as before; a "checks payable to" name stands in.
    def payment_instructions
      text = billing["payment_instructions"].to_s.strip.presence
      text = nil if text == DEFAULT_PAYMENT_TEXT
      return text if text
      return nil if billing["remit_to"].blank?

      "Make checks payable to #{billing['remit_to']}."
    end

    def invoice_date
      parse_date(invoice["invoice_date"])
    end

    def due_date
      parse_date(invoice["due_date"])
    end

    def service_start
      parse_date(invoice["service_period_start"])
    end

    def service_end
      parse_date(invoice["service_period_end"])
    end

    def service_period?
      service_start.present? || service_end.present?
    end

    # "November 2026" for a whole calendar month, otherwise the date range.
    def service_period_label
      return nil unless service_period?
      return service_start.strftime("%B %Y") if full_month?

      service_period_range
    end

    def service_period_range
      return nil unless service_period?

      [ short_date(service_start), short_date(service_end) ].compact.join(" – ")
    end

    def full_month?
      service_start && service_end && service_start == service_start.beginning_of_month &&
        service_end == service_start.end_of_month
    end

    def subtotal
      invoice["subtotal_amount"].presence || invoice["total_amount"]
    end

    def total
      invoice["total_amount"]
    end

    def discount?
      decimal(invoice["discount_amount"]).positive?
    end

    def discount_label
      return "Discount" unless invoice["discount_type"] == "percent"

      "Discount (#{format_decimal(invoice['discount_value'])}%)"
    end

    def discount_amount
      "-#{money(invoice['discount_amount'])}"
    end

    def service_dates?
      lines.any? { |line| line["service_date"].present? }
    end

    def item_names?
      lines.any? { |line| line["item_name"].present? }
    end

    def initials
      words = sender_name.scan(/[[:alnum:]]+/)
      letters = words.first(2).map { |word| word[0] }
      letters = [ words.first.to_s[0, 2] ] if words.one?
      letters.join.upcase.presence || "?"
    end

    def money(value)
      number_to_currency(value || 0)
    end

    def format_decimal(value)
      number_with_precision(value || 0, precision: 2, delimiter: ",")
    end

    # 1 rather than 1.00; fractional quantities keep their decimals.
    def quantity(value)
      number_with_precision(decimal(value), precision: 4, strip_insignificant_zeros: true, delimiter: ",")
    end

    def short_date(date)
      date&.strftime("%m/%d/%Y")
    end

    def long_date(date)
      date && "#{date.strftime('%B')} #{date.day}, #{date.year}"
    end

    def abbreviated_date(date)
      date && "#{date.strftime('%b')} #{date.day}, #{date.year}"
    end

    def line_date(line)
      short_date(parse_date(line["service_date"]))
    end

    private

    def split_lines(value)
      value.to_s.split("\n").map(&:strip).compact_blank
    end

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value.to_s)
    rescue Date::Error
      nil
    end

    def decimal(value)
      BigDecimal((value.presence || 0).to_s)
    rescue ArgumentError
      BigDecimal("0")
    end
  end
end
