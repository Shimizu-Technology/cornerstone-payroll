# frozen_string_literal: true

# The email that carries an invoice. It is delivery content, not invoice
# evidence: it can change after issue without touching the issued PDF or
# snapshot. A blank saved subject or body means "use the default", which is
# worked out when the email is shown or sent so it always names the issued
# number and the current balance.
#
# The default follows how the office sends invoices today:
#   Subject: Invoice 07052 - MoSa's Hot Box, Inc. - November 2026
#   Body:    greeting, the invoice is attached, the amount and due date,
#            then the sender's footer or thanks.
class InvoiceEmailContent
  SEPARATOR = " - "

  def self.for(invoice)
    new(invoice).to_h
  end

  def self.default_subject(invoice)
    new(invoice).default_subject
  end

  def self.default_body(invoice)
    new(invoice).default_body
  end

  def initialize(invoice)
    @invoice = invoice
  end

  # subject/body are what would be sent now; the default_* values let a
  # screen offer "use the default" and tell a saved message from a default.
  def to_h
    {
      subject: invoice.email_subject.presence || default_subject,
      body: invoice.email_body.presence || default_body,
      default_subject: default_subject,
      default_body: default_body,
      subject_customized: invoice.email_subject.present?,
      body_customized: invoice.email_body.present?
    }
  end

  # Always fits Invoice::EMAIL_SUBJECT_MAX. A long customer name is
  # shortened first, so "Invoice <number>" and the service month stay whole.
  def default_subject
    prefix = "Invoice #{number}"
    customer = invoice.invoice_recipient&.name.to_s.squish.presence
    service = service_label
    subject = [ prefix, customer, service ].compact.join(SEPARATOR)
    return subject if subject.length <= Invoice::EMAIL_SUBJECT_MAX

    if customer
      room = Invoice::EMAIL_SUBJECT_MAX - prefix.length - SEPARATOR.length - (service ? service.length + SEPARATOR.length : 0)
      subject = [ prefix, (customer.truncate(room, omission: "…") if room >= 2), service ].compact.join(SEPARATOR)
    end
    subject.truncate(Invoice::EMAIL_SUBJECT_MAX, omission: "…")
  end

  def default_body
    attached = "Please find attached invoice #{number}"
    attached += " for #{service_label}" if service_label
    lines = [
      "Hello,",
      "",
      "#{attached}. The amount due is #{[ amount(invoice.balance_due), due_phrase ].compact.join(', ')}.",
      "",
      profile&.footer_note.presence || InvoiceBillingProfile::DEFAULT_FOOTER
    ]
    lines << sender_name if sender_name
    lines.join("\n")
  end

  private

  attr_reader :invoice

  def profile
    invoice.invoice_billing_profile
  end

  def sender_name
    profile&.legal_name.presence || profile&.name.presence
  end

  # A draft has no number yet; show the number it would take so the default
  # reads the way it will once issued.
  def number
    return invoice.invoice_number unless invoice.invoice_number.to_s.start_with?("DRAFT-")
    return "Draft" unless profile

    profile.next_number_preview(invoice.invoice_date || PayrollBusinessClock.today)
  end

  # Whole calendar months read as months ("November 2026",
  # "October - November 2026"); any other span reads as dates.
  def service_label
    start_on = invoice.service_period_start
    end_on = invoice.service_period_end
    return invoice.invoice_date&.strftime("%B %Y") if start_on.blank? || end_on.blank?

    if start_on == start_on.beginning_of_month && end_on == end_on.end_of_month
      return start_on.strftime("%B %Y") if start_on.beginning_of_month == end_on.beginning_of_month
      return "#{start_on.strftime('%B')} - #{end_on.strftime('%B %Y')}" if start_on.year == end_on.year

      return "#{start_on.strftime('%B %Y')} - #{end_on.strftime('%B %Y')}"
    end
    return start_on.strftime("%B %-d, %Y") if start_on == end_on

    "#{start_on.strftime('%B %-d, %Y')} - #{end_on.strftime('%B %-d, %Y')}"
  end

  def due_phrase
    return "due on receipt" if invoice.payment_terms.to_s.strip.casecmp?("Due on receipt")

    "due by #{invoice.due_date.strftime('%B %-d, %Y')}" if invoice.due_date.present?
  end

  def amount(value)
    formatted = ActiveSupport::NumberHelper.number_to_delimited(format("%.2f", value.to_d))
    invoice.currency.to_s.upcase == "USD" || invoice.currency.blank? ? "$#{formatted}" : "#{invoice.currency.upcase} #{formatted}"
  end
end
