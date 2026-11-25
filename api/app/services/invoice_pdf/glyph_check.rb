# frozen_string_literal: true

module InvoicePdf
  # Finds characters an invoice PDF can't print. Every renderer falls back to
  # Liberation Sans and Payroll CJK. Unsupported characters such as emoji
  # and tabs print as boxes. Drafts show the problem in the editor and the
  # preview; issuing refuses it, so no issued PDF contains boxes.
  module GlyphCheck
    INVOICE_FIELDS = {
      "invoice_number" => "Invoice number",
      "customer_reference" => "Customer reference",
      "payment_terms" => "Payment terms",
      "notes" => "Notes"
    }.freeze
    BILLING_FIELDS = {
      "name" => "Billing profile name",
      "legal_name" => "Billing profile legal name",
      "address" => "Billing profile address",
      "email" => "Billing profile email",
      "phone" => "Billing profile phone",
      "website" => "Billing profile website",
      "payment_instructions" => "Payment instructions",
      "remit_to" => "Checks payable to",
      "footer_note" => "Footer note"
    }.freeze
    RECIPIENT_FIELDS = {
      "name" => "Customer name",
      "address" => "Customer address",
      "email" => "Customer email"
    }.freeze

    module_function

    # [{ "field" => "Customer name", "characters" => ["😀"] }, ...]
    def problems(snapshot)
      return [] unless snapshot.is_a?(Hash)

      fields = section(snapshot["invoice"], INVOICE_FIELDS) +
               section(snapshot["billing_profile"], BILLING_FIELDS) +
               section(snapshot["recipient"], RECIPIENT_FIELDS) +
               Array(snapshot["line_items"]).each_with_index.flat_map do |line, index|
                 [ [ "Line #{index + 1} product or service", line["item_name"] ],
                   [ "Line #{index + 1} description", line["description"] ] ]
               end
      fields.filter_map do |label, value|
        characters = PdfUnicodeFont.unprintable_characters(value)
        { "field" => label, "characters" => characters.map { |char| visible(char) } } if characters.any?
      end
    end

    def message(problems)
      details = problems.map { |problem| "#{problem['field']} (#{problem['characters'].join(' ')})" }.join("; ")
      "The invoice PDF can't print some characters, so they would appear as empty boxes: #{details}. " \
        "Replace them with Latin letters, then try again."
    end

    def section(values, labels)
      return [] unless values.is_a?(Hash)

      labels.map { |key, label| [ label, values[key] ] }
    end

    # Invisible characters (tabs, joiners) are named by code point.
    def visible(char)
      char.match?(/[\p{L}\p{M}\p{N}\p{P}\p{S}]/) ? char : format("U+%04X", char.ord)
    end
  end
end
