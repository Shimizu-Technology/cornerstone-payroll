# frozen_string_literal: true

class InvoiceCreditService
  def self.issue!(invoice:, actor:, amount:, issue_date:, reason:)
    Invoice.transaction do
      invoice = Invoice.lock.find(invoice.id)
      raise ArgumentError, "Draft invoices cannot receive credits" if invoice.draft?
      raise ArgumentError, "Voided invoices cannot receive credits" if invoice.voided?
      raise ArgumentError, "Uncollectible invoices cannot receive credits" if invoice.uncollectible?

      amount = BigDecimal(amount.to_s)
      raise ArgumentError, "Credit amount must be greater than zero" unless amount.positive?
      raise ArgumentError, "Credit exceeds the remaining invoice balance" if amount > invoice.balance_due
      raise ArgumentError, "Credit reason is required" if reason.blank?

      credit = invoice.credit_notes.create!(
        organization: invoice.organization,
        credit_number: next_credit_number(invoice),
        issue_date: issue_date,
        reason: reason,
        total_amount: amount,
        currency: invoice.currency,
        issued_by: actor
      )
      invoice.update!(paid_at: Time.current, updated_by: actor) if invoice.reload.balance_due.zero?
      InvoiceEvent.record!(
        invoice: invoice,
        event_type: "credit_issued",
        actor: actor,
        occurred_at: credit.issue_date.in_time_zone,
        metadata: { credit_note_id: credit.id, credit_number: credit.credit_number, amount: credit.total_amount.to_s }
      )
      credit
    end
  end

  def self.void!(credit_note:, actor:, reason:)
    Invoice.transaction do
      invoice = Invoice.lock.find(credit_note.invoice_id)
      credit_note = InvoiceCreditNote.lock.find_by!(id: credit_note.id, invoice_id: invoice.id)
      raise ArgumentError, "Credit is already voided" if credit_note.voided?
      raise ArgumentError, "Void reason is required" if reason.blank?

      credit_note.update!(status: "voided", voided_at: Time.current, voided_by: actor, void_reason: reason)
      invoice.update!(paid_at: nil, updated_by: actor)
      InvoiceEvent.record!(
        invoice: invoice,
        event_type: "credit_voided",
        actor: actor,
        metadata: { credit_note_id: credit_note.id, amount: credit_note.total_amount.to_s, reason: reason }
      )
      credit_note
    end
  end

  def self.next_credit_number(invoice)
    "CN-#{invoice.invoice_date.year}-#{invoice.id}-#{invoice.credit_notes.count + 1}"
  end

  private_class_method :next_credit_number
end
