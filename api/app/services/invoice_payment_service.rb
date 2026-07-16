# frozen_string_literal: true

class InvoicePaymentService
  def self.record!(invoice:, actor:, amount:, received_on:, payment_method:, currency:, reference_number: nil, notes: nil)
    Invoice.transaction do
      invoice = Invoice.lock.find(invoice.id)
      ensure_payable!(invoice)
      amount = BigDecimal(amount.to_s)
      raise ArgumentError, "Payment amount must be greater than zero" unless amount.positive?
      raise ArgumentError, "Payment exceeds the remaining invoice balance" if amount > invoice.balance_due

      payment = invoice.payments.create!(
        organization: invoice.organization,
        amount: amount,
        received_on: received_on,
        payment_method: payment_method,
        currency: currency.presence || invoice.currency,
        reference_number: reference_number,
        notes: notes,
        recorded_by: actor
      )
      invoice.update!(paid_at: Time.current, updated_by: actor) if invoice.reload.balance_due.zero?
      InvoiceEvent.record!(
        invoice: invoice,
        event_type: "payment_recorded",
        actor: actor,
        occurred_at: payment.received_on.in_time_zone,
        metadata: { payment_id: payment.id, amount: payment.amount.to_s, method: payment.payment_method }
      )
      payment
    end
  end

  def self.reverse!(payment:, actor:, reason:)
    Invoice.transaction do
      invoice = Invoice.lock.find(payment.invoice_id)
      payment = InvoicePayment.lock.find_by!(id: payment.id, invoice_id: invoice.id)
      raise ArgumentError, "Payment has already been reversed" if payment.reversed?
      raise ArgumentError, "Reversal reason is required" if reason.blank?

      payment.update!(reversed_at: Time.current, reversed_by: actor, reversal_reason: reason)
      invoice.update!(paid_at: nil, updated_by: actor)
      InvoiceEvent.record!(
        invoice: invoice,
        event_type: "payment_reversed",
        actor: actor,
        metadata: { payment_id: payment.id, amount: payment.amount.to_s, reason: reason }
      )
      payment
    end
  end

  def self.ensure_payable!(invoice)
    raise ArgumentError, "Draft invoices cannot receive payments" if invoice.draft?
    raise ArgumentError, "Voided invoices cannot receive payments" if invoice.voided?
    raise ArgumentError, "Uncollectible invoices cannot receive payments" if invoice.uncollectible?
    raise ArgumentError, "Invoice is already fully paid" if invoice.balance_due.zero?
  end

  private_class_method :ensure_payable!
end
