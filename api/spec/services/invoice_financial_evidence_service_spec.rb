# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invoice financial evidence services" do
  let!(:actor) { create(:user) }
  let!(:invoice) do
    create(
      :invoice,
      :with_line_item,
      :generated,
      company: actor.company,
      organization: actor.organization
    )
  end

  it "locks the invoice before reversing a payment" do
    payment = InvoicePaymentService.record!(
      invoice: invoice,
      actor: actor,
      amount: invoice.total_amount,
      received_on: Date.current,
      payment_method: "ach",
      currency: invoice.currency
    )
    invoice_lock = Invoice.lock
    payment_lock = InvoicePayment.lock
    allow(Invoice).to receive(:lock).and_return(invoice_lock)
    allow(InvoicePayment).to receive(:lock).and_return(payment_lock)
    expect(invoice_lock).to receive(:find).with(invoice.id).ordered.and_call_original
    expect(payment_lock).to receive(:find_by!)
      .with(id: payment.id, invoice_id: invoice.id)
      .ordered
      .and_call_original

    InvoicePaymentService.reverse!(payment: payment, actor: actor, reason: "Returned ACH")

    expect(invoice.reload).to have_attributes(paid_at: nil, balance_due: invoice.total_amount)
    expect(payment.reload).to have_attributes(reversed_at: be_present, reversal_reason: "Returned ACH")
  end

  it "locks the invoice before voiding a credit" do
    credit = InvoiceCreditService.issue!(
      invoice: invoice,
      actor: actor,
      amount: invoice.total_amount,
      issue_date: Date.current,
      reason: "Full adjustment"
    )
    invoice_lock = Invoice.lock
    credit_lock = InvoiceCreditNote.lock
    allow(Invoice).to receive(:lock).and_return(invoice_lock)
    allow(InvoiceCreditNote).to receive(:lock).and_return(credit_lock)
    expect(invoice_lock).to receive(:find).with(invoice.id).ordered.and_call_original
    expect(credit_lock).to receive(:find_by!)
      .with(id: credit.id, invoice_id: invoice.id)
      .ordered
      .and_call_original

    InvoiceCreditService.void!(credit_note: credit, actor: actor, reason: "Issued in error")

    expect(invoice.reload).to have_attributes(paid_at: nil, balance_due: invoice.total_amount)
    expect(credit.reload).to have_attributes(status: "voided", void_reason: "Issued in error")
  end
end
