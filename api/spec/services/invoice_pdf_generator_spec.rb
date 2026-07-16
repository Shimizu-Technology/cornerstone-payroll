# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe InvoicePdfGenerator do
  let(:invoice) do
    create(
      :invoice,
      :with_line_item,
      customer_reference: "CUSTOMER-REF-2026",
      payment_terms: "Due within 16 days"
    )
  end

  def reader_for(invoice)
    PDF::Reader.new(StringIO.new(described_class.new(invoice.reload).generate))
  end

  it "generates a readable PDF with the core invoice content" do
    reader = reader_for(invoice)
    text = reader.pages.map(&:text).join("\n")

    expect(text).to include(invoice.invoice_number, "CUSTOMER-REF-2026", "Payroll services", "Due within 16 days")
  end

  it "keeps the party cards below dynamic invoice metadata" do
    runs = reader_for(invoice).pages.first.runs
    status = runs.find { |run| run.text == "Status" }
    bill_to = runs.find { |run| run.text == "BILL TO" }
    remit_to = runs.find { |run| run.text == "REMIT TO" }

    expect(status).to be_present
    expect(bill_to).to be_present
    expect(remit_to).to be_present
    expect(status.y - remit_to.y).to be > 30
    expect(bill_to.y).to be_within(0.5).of(remit_to.y)
  end

  it "vertically aligns terms and total due and omits an unused service-date column" do
    invoice.invoice_billing_profile.update!(payment_instructions: nil)
    runs = reader_for(invoice).pages.first.runs
    terms = runs.find { |run| run.text == "TERMS" }
    total_due = runs.find { |run| run.text == "TOTAL DUE" }

    expect(terms.y).to be_within(4).of(total_due.y)
    expect(runs.none? { |run| run.text == "Date" }).to be(true)
  end

  it "includes the service-date column when at least one line item uses it" do
    invoice.line_items.first.update!(service_date: Date.new(2026, 5, 2))

    runs = reader_for(invoice).pages.first.runs

    expect(runs.any? { |run| run.text == "Date" }).to be(true)
  end

  it "flows long invoices across pages without losing the final line item" do
    45.times do |index|
      invoice.line_items.create!(
        description: "Professional service line #{index + 2} with enough detail for a real customer invoice",
        quantity: 1,
        rate: 25,
        position: index + 1
      )
    end

    reader = reader_for(invoice)

    expect(reader.page_count).to be > 1
    expect(reader.pages.last.text).to include("Professional service line 46")
    reader.pages.each do |page|
      footer_runs = page.runs.select { |run| run.y < 40 }
      content_runs = page.runs.reject { |run| run.y < 40 }

      expect(footer_runs).to be_present
      expect(content_runs.map(&:y).min).to be > 60
    end
  end
end
