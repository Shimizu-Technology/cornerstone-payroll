# frozen_string_literal: true

module InvoicePdf
  # A made-up invoice for the style preview and "Download sample PDF". It
  # uses the profile's own name, address, payment text and saved services,
  # with a fictional customer and amounts. Its status is "sample", so every
  # page says it is a sample rather than an invoice.
  module Sample
    module_function

    def snapshot(profile, today: PayrollBusinessClock.today)
      month = today.beginning_of_month
      lines = sample_lines(profile, month)
      total = lines.sum { |line| BigDecimal(line["amount"]) }
      terms = profile.default_payment_terms.presence || "Net 15"
      {
        "version" => Invoice::SNAPSHOT_VERSION,
        "invoice" => {
          "invoice_number" => sample_number(profile, today),
          "invoice_date" => today.iso8601,
          "due_date" => due_date(terms, today)&.iso8601,
          "currency" => "USD",
          "service_period_start" => month.iso8601,
          "service_period_end" => month.end_of_month.iso8601,
          "status" => "sample",
          "payment_terms" => terms,
          "total_amount" => total.to_s("F"),
          "subtotal_amount" => total.to_s("F"),
          "discount_type" => "none",
          "discount_value" => "0",
          "discount_amount" => "0"
        },
        "billing_profile" => profile.attributes.slice(
          "name", "legal_name", "website", "phone", "email", "address", "payment_instructions",
          "default_payment_terms", "remit_to", "footer_note", "logo_storage_key", "logo_content_type", "logo_sha256"
        ),
        "recipient" => {
          "name" => "Sample Client LLC",
          "address" => "Attn: Accounts Payable\n100 Example Avenue, Suite 2\nHagåtña, GU 96910"
        },
        "line_items" => lines,
        "style" => profile.invoice_style.to_snapshot
      }
    end

    # Same rule as Invoice#default_due_date: "Net N" and "Due on receipt"
    # set a date; other terms leave it blank rather than contradict them.
    def due_date(terms, today)
      days = terms.to_s.match(/\ANet\s+(\d+)\z/i)&.captures&.first
      return today + days.to_i if days

      today if terms.to_s.casecmp?("Due on receipt")
    end

    def sample_number(profile, today)
      return profile.next_invoice_number.to_s if profile.numbering_style == "continuing"

      "#{profile.invoice_prefix.presence || 'INV'}-#{today.year}-0001"
    end

    def sample_lines(profile, month)
      catalog = Array(profile.service_catalog)
      fee = catalog.find { |entry| entry["line_kind"] == "service_fee" }
      reimbursement = catalog.find { |entry| entry["line_kind"] == "reimbursement" }
      month_label = month.strftime("%B %Y")
      prior_month = month.prev_month.strftime("%B %Y")
      [
        line(fee&.dig("name") || "Accounting Consulting",
             fee ? fee["description_template"].gsub("{month}", month_label) : "Accounting Services – #{month_label}",
             "3000.00", "service_fee"),
        line(reimbursement&.dig("name") || "Reimbursement",
             if reimbursement
               reimbursement["description_template"].gsub("{month}", prior_month)
             else
               "Social Security and Medicare paid on the client's behalf – #{prior_month} payroll"
             end,
             "1234.56", "reimbursement")
      ]
    end

    def line(name, description, amount, kind)
      { "line_kind" => kind, "item_name" => name, "description" => description, "quantity" => "1",
        "rate" => amount, "amount" => amount, "service_date" => nil, "position" => 0 }
    end
  end
end
