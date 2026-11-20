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

  it "preserves extra fees and reviews zeroed reimbursements across a quarterly interval" do
    source = create(:invoice, :with_line_item)
    source.invoice_billing_profile.update!(numbering_style: "continuing")
    source.invoice_recipient.update!(default_rate: 700, payment_terms: "Net 15")
    source.line_items.create!(description: "Extra filing", quantity: 1, rate: 80, position: 1)
    source.line_items.create!(item_name: "Reimbursement", description: "Tax payment", quantity: 1, rate: 125, line_kind: "reimbursement", position: 2)
    source.save!
    source.issue!(actor: nil)
    recurrence = InvoiceRecurrence.create!(organization: source.organization, finance_book: source.finance_book,
      source_invoice: source, start_on: Date.new(2026, 6, 15), next_on: Date.new(2026, 6, 15),
      interval_unit: "month", interval_count: 3, due_after_days: 30)
    draft = InvoiceRecurrenceGenerator.generate!(recurrence.id, today: Date.new(2026, 6, 15))
    expect(draft).to have_attributes(service_period_start: Date.new(2026, 6, 15), service_period_end: Date.new(2026, 9, 14), due_date: Date.new(2026, 6, 30))
    expect(draft.due_date_manual).to be(false)
    draft.update!(invoice_date: Date.new(2026, 6, 16))
    expect(draft.due_date).to eq(Date.new(2026, 7, 1))
    expect(draft.line_items.map(&:rate)).to eq([ 700, 80, 0 ])
    expect(draft.line_items.last.reimbursement_review_required).to be(true)
    expect { draft.issue!(actor: nil) }.to raise_error(ActiveRecord::RecordInvalid, /reimbursement/)
    draft.line_items.last.update!(rate: 140)
    draft.issue!(actor: nil)
    expect(draft.reload.status).to eq("open")
  end

  it "keeps ST recurrence terms, rates, descriptions and scheduled due days unchanged" do
    source = create(:invoice, :with_line_item, payment_terms: "Net 30")
    source.invoice_recipient.update!(default_rate: 999, payment_terms: "Net 15")
    source.line_items.first.update!(description: "Services May 2026")
    source.issue!(actor: nil)
    recurrence = InvoiceRecurrence.create!(organization: source.organization, finance_book: source.finance_book,
      source_invoice: source, start_on: Date.new(2026, 6, 15), next_on: Date.new(2026, 6, 15),
      interval_unit: "month", interval_count: 1, due_after_days: 7)
    draft = InvoiceRecurrenceGenerator.generate!(recurrence.id, today: Date.new(2026, 6, 15))
    expect(draft).to have_attributes(payment_terms: "Net 30", due_date: Date.new(2026, 6, 22), service_period_start: Date.new(2026, 6, 15), service_period_end: Date.new(2026, 7, 14))
    expect(draft.line_items.first).to have_attributes(rate: 150.to_d, description: "Services May 2026")
  end

  [
    { reimbursement: 1000, fee: 300, discount: 400, expected: 300 },
    { reimbursement: 0, fee: 100, discount: 200, expected: 100 },
    { reimbursement: 1000, fee: 300, discount: 0, expected: 0 }
  ].each do |scenario|
    it "completes and advances recurring drafts with discount #{scenario[:discount]}, fee #{scenario[:fee]} and reimbursement #{scenario[:reimbursement]}" do
      source = create(:invoice, :with_line_item)
      source.invoice_billing_profile.update!(numbering_style: "continuing")
      source.line_items.first.update!(quantity: 1, rate: 500)
      if scenario[:reimbursement].positive?
        source.line_items.create!(description: "Tax payment", quantity: 1, rate: scenario[:reimbursement], line_kind: "reimbursement", position: 1)
      end
      source.update!(discount_type: scenario[:discount].positive? ? "amount" : "none", discount_value: scenario[:discount])
      source.issue!(actor: nil)
      source.invoice_recipient.update!(default_rate: scenario[:fee])
      recurrence = InvoiceRecurrence.create!(organization: source.organization, finance_book: source.finance_book,
        source_invoice: source, start_on: Date.new(2026, 6, 1), next_on: Date.new(2026, 6, 1),
        interval_unit: "month", interval_count: 1, due_after_days: 15)
      InvoiceRecurrenceGenerator.generate_due!(today: Date.new(2026, 6, 1))
      draft = recurrence.generated_invoices.sole
      expect(draft).to have_attributes(status: "draft", discount_value: scenario[:expected].to_d, total_amount: (scenario[:fee] - scenario[:expected]).to_d)
      expect(recurrence.reload.next_on).to eq(Date.new(2026, 7, 1))
      if scenario[:discount].positive?
        expect(draft.notes).to include("Review recurring discount", "capped")
        expect(draft.events.find_by!(event_type: "recurring_discount_capped").metadata).to include(
          "original_discount" => scenario[:discount].to_d.to_s("F"), "capped_discount" => scenario[:expected].to_d.to_s("F"))
      else
        expect(draft.events.where(event_type: "recurring_discount_capped")).to be_empty
        expect(draft.notes).to eq(source.notes)
      end
      expect { InvoiceRecurrenceGenerator.generate_due!(today: Date.new(2026, 6, 1)) }.not_to change(Invoice, :count)
    end
  end

  it "groups discounted issued fees by client and service month with explicit legacy boundaries" do
    invoice = create(:invoice, :with_line_item, discount_type: "amount", discount_value: 40)
    invoice.line_items.create!(description: "Taxes", quantity: 1, rate: 100, line_kind: "reimbursement", position: 1)
    invoice.save!
    invoice.issue!(actor: nil)
    create(:invoice, :with_line_item, company: invoice.company, finance_book: invoice.finance_book)
    imported = create(:invoice, organization: invoice.organization, finance_book: invoice.finance_book,
      invoice_billing_profile: invoice.invoice_billing_profile, invoice_recipient: invoice.invoice_recipient,
      company: nil, origin: "imported", total_amount: 200)
    imported.update_columns(status: "open")
    expect(InvoiceServiceFeeRevenue.call(finance_book: invoice.finance_book, service_month_from: Date.new(2026, 6, 1))).to be_empty
    expect(InvoiceServiceFeeRevenue.call(finance_book: invoice.finance_book, service_month_through: Date.new(2026, 4, 1))).to be_empty
    rows = InvoiceServiceFeeRevenue.call(finance_book: invoice.finance_book, service_month_from: Date.new(2026, 5, 15), service_month_through: Date.new(2026, 5, 15))
    expect(rows).to include(company_id: invoice.company_id, service_month: Date.new(2026, 5, 1), amount: 270.to_d)
    expect(rows).to include(company_id: nil, service_month: Date.new(2026, 5, 1), amount: 0.to_d)
    invoice.void!(actor: nil, reason: "Test replacement")
    expect(InvoiceServiceFeeRevenue.call(finance_book: invoice.finance_book).sum { |row| row[:amount] }).to eq(0)
  end

  it "defaults an omitted model rate while preserving an explicit zero" do
    recipient = create(:invoice_recipient, default_rate: 700, payment_terms: "Net 15")
    profile = create(:invoice_billing_profile, organization: recipient.organization, finance_book: recipient.finance_book)
    attrs = { invoice_recipient: recipient, organization: recipient.organization, company: recipient.company,
              invoice_billing_profile: profile, invoice_date: Date.new(2026, 11, 2) }
    invoice = Invoice.new(attrs)
    invoice.line_items.build(description: "Monthly service", quantity: 1)
    invoice.save!
    expect(invoice.line_items.first.rate).to eq(700.to_d)
    expect(invoice.payment_terms).to eq("Net 15")
    zero = Invoice.new(attrs)
    zero.line_items.build(description: "No charge", quantity: 1, rate: 0)
    zero.save!
    expect(zero.line_items.first.rate).to eq(0)
  end

  it "rejects malformed catalog entries and line classifications" do
    profile = build(:invoice_billing_profile, service_catalog: [ { name: "Broken" } ])
    expect(profile).not_to be_valid
    invoice = build(:invoice, :with_line_item)
    invoice.line_items.first.line_kind = "unknown"
    expect(invoice).not_to be_valid
  end
end
