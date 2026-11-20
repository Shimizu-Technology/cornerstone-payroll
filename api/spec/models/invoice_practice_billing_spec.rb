# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Practice billing" do
  it "reserves continuing numbers at issue, skips collisions and continues across years" do
    profile = create(:invoice_billing_profile, numbering_style: "continuing", next_invoice_number: 7055)
    draft = create(:invoice, :with_line_item, invoice_billing_profile: profile, company: nil, organization: profile.organization,
                    invoice_recipient: create(:invoice_recipient, company: nil, organization: profile.organization), invoice_number: nil)
    expect(draft.invoice_number).to start_with("DRAFT-")
    expect(profile.reload.next_invoice_number).to eq(7055)
    draft.issue!(actor: nil)
    expect(draft.reload.invoice_number).to eq("7055")
    expect(draft.snapshot.dig("invoice", "invoice_number")).to eq("7055")
    expect(InvoiceNumberAllocator.call(billing_profile: profile, invoice_date: "2027-01-01")).to eq("7056")
    profile.update!(next_invoice_number: 7055)
    expect(InvoiceNumberAllocator.call(billing_profile: profile, invoice_date: "2027-01-01")).to eq("7056")
  end

  it "separates reimbursements from billed fees without reducing the receivable" do
    invoice = create(:invoice, :with_line_item, discount_type: "percent", discount_value: 10)
    invoice.line_items.create!(description: "Social Security and Medicare", quantity: 1, rate: 100, position: 1, line_kind: "reimbursement")
    invoice.save!
    invoice.issue!(actor: nil)
    expect(invoice.total_amount).to eq(360)
    expect(invoice.service_fee_amount).to eq(270)
    expect(invoice.balance_due).to eq(360)
    expect(invoice.snapshot.fetch("line_items").last.fetch("line_kind")).to eq("reimbursement")
    invoice.void!(actor: nil, reason: "Replaced")
    expect(invoice.service_fee_amount).to eq(0)
  end

  it "creates a monthly review draft with the current customer fee, terms and service month" do
    source = create(:invoice, :with_line_item)
    source.invoice_billing_profile.update!(numbering_style: "continuing", next_invoice_number: 7055)
    source.invoice_recipient.update!(default_rate: 700, payment_terms: "Net 30")
    source.update!(service_period_start: Date.new(2026, 5, 1), service_period_end: Date.new(2026, 5, 31))
    source.line_items.first.update!(description: "Accounting Services – May 2026", quantity: 1)
    source.save!
    source.issue!(actor: nil)
    recurrence = InvoiceRecurrence.create!(organization: source.organization, finance_book: source.finance_book,
                                           source_invoice: source, start_on: Date.new(2026, 6, 1), next_on: Date.new(2026, 6, 1),
                                           interval_unit: "month", interval_count: 1, due_after_days: 15)
    draft = InvoiceRecurrenceGenerator.generate!(recurrence.id, today: Date.new(2026, 6, 1))
    expect(draft).to have_attributes(status: "draft", total_amount: 700.to_d, payment_terms: "Net 30",
                                    service_period_start: Date.new(2026, 6, 1), service_period_end: Date.new(2026, 6, 30),
                                    due_date: Date.new(2026, 7, 1))
    expect(draft.invoice_number).to start_with("DRAFT-")
    expect(draft.line_items.first.description).to eq("Accounting Services – June 2026")
    expect(source.invoice_billing_profile.reload.next_invoice_number).to eq(7055)
  end

  it "rejects malformed catalog entries and line classifications" do
    profile = build(:invoice_billing_profile, service_catalog: [ { name: "Broken" } ])
    expect(profile).not_to be_valid
    invoice = build(:invoice, :with_line_item)
    invoice.line_items.first.line_kind = "unknown"
    expect(invoice).not_to be_valid
  end
end
