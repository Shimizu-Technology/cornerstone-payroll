# frozen_string_literal: true

class InvoiceRecurrenceGenerator
  def self.generate_due!(today: nil)
    InvoiceRecurrence.where(active: true).where("next_on <= ?", today || Date.current + 1).order(:id).pluck(:id).each do |id|
      begin
        120.times { break unless generate!(id, today: today) }
      rescue StandardError => e
        Rails.logger.error("Invoice recurrence #{id} failed: #{e.class}: #{e.message}")
      end
    end
  end

  def self.generate!(id, today: nil)
    InvoiceRecurrence.transaction do
      recurrence = InvoiceRecurrence.lock.find(id)
      local_today = today || ActiveSupport::TimeZone[recurrence.time_zone].today
      return unless recurrence.active? && recurrence.next_on <= local_today
      if recurrence.ends_on.present? && recurrence.next_on > recurrence.ends_on
        recurrence.update!(active: false)
        return
      end

      date = recurrence.next_on
      source = recurrence.source_invoice
      unless source.origin == "native" && source.issued? && !source.voided? && usable_source?(source)
        recurrence.update!(active: false)
        return
      end

      invoice = Invoice.find_by(invoice_recurrence_id: recurrence.id, recurrence_on: date)
      unless invoice
        original = source.snapshot.fetch("invoice")
        invoice = Invoice.new(
          organization: recurrence.organization,
          finance_book: recurrence.finance_book,
          company: source.company,
          invoice_billing_profile: source.invoice_billing_profile,
          invoice_recipient: source.invoice_recipient,
          invoice_recurrence: recurrence,
          recurrence_on: date,
          invoice_date: date,
          due_date: date + recurrence.due_after_days,
          service_period_start: date,
          service_period_end: recurrence.occurrence_date(recurrence.occurrence_index + 1) - 1,
          currency: original["currency"],
          customer_reference: original["customer_reference"],
          notes: original["notes"],
          payment_terms: original["payment_terms"],
          email_subject: original["email_subject"],
          email_body: original["email_body"],
          discount_type: original["discount_type"] || "none",
          discount_value: original["discount_value"] || 0,
          created_by: recurrence.created_by,
          updated_by: recurrence.created_by
        )
        source.snapshot.fetch("line_items").each_with_index do |line, position|
          invoice.line_items.build(
            description: line.fetch("description"),
            quantity: line.fetch("quantity"),
            rate: line.fetch("rate"),
            position: position
          )
        end
        invoice.save!
        InvoiceEvent.record!(invoice: invoice, event_type: "recurring_draft_created", actor: recurrence.created_by,
                             metadata: { recurrence_id: recurrence.id, occurrence_on: date.iso8601 })
      end
      recurrence.advance!
      invoice
    end
  end

  def self.usable_source?(source)
    snapshot = source.snapshot
    return false unless snapshot.is_a?(Hash) && snapshot["invoice"].is_a?(Hash)

    lines = snapshot["line_items"]
    lines.is_a?(Array) && lines.present? && lines.all? do |line|
      line.is_a?(Hash) && %w[description quantity rate].all? { |key| line.key?(key) }
    end
  end
end
