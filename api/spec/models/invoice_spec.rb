# frozen_string_literal: true

require "rails_helper"

RSpec.describe Invoice, type: :model do
  it "calculates total amount from line items" do
    invoice = build(:invoice, :with_line_item)
    invoice.line_items.build(description: "Bookkeeping", quantity: 1.5, rate: 80, position: 1)

    expect(invoice).to be_valid
    expect(invoice.total_amount).to eq(420)
  end

  it "requires line items when generated" do
    invoice = build(:invoice, status: "generated")

    expect(invoice).not_to be_valid
    expect(invoice.errors[:line_items]).to include("must include at least one line item")
  end

  it "assigns an invoice number when one is not supplied" do
    recipient = create(:invoice_recipient, invoice_prefix: "CS")
    billing_profile = create(:invoice_billing_profile, organization: recipient.organization, invoice_prefix: "ST")
    invoice = create(
      :invoice,
      :with_line_item,
      company: recipient.company,
      invoice_recipient: recipient,
      invoice_billing_profile: billing_profile,
      invoice_number: nil
    )

    expect(invoice.invoice_number).to match(/\AST-\d{4}-\d{4}\z/)
  end

  it "captures a billing and recipient snapshot when generated" do
    billing_profile = create(:invoice_billing_profile, name: "Shimizu Technology", invoice_prefix: "ST")
    recipient = create(:invoice_recipient, company: billing_profile.organization.companies.first || create(:company, organization: billing_profile.organization), name: "Pacific Client")
    invoice = create(:invoice, :with_line_item, company: recipient.company, organization: billing_profile.organization, invoice_billing_profile: billing_profile, invoice_recipient: recipient)

    invoice.mark_generated!(actor: nil)

    expect(invoice.snapshot.dig("billing_profile", "name")).to eq("Shimizu Technology")
    expect(invoice.snapshot.dig("recipient", "name")).to eq("Pacific Client")
    expect(invoice.snapshot.fetch("line_items").first.fetch("description")).to eq("Payroll services")
  end

  it "rejects backward status transitions" do
    invoice = create(:invoice, :with_line_item, :generated, status: "paid")
    actor = create(:user, company: invoice.company)

    expect {
      invoice.update_status!("sent", actor: actor)
    }.to raise_error(ActiveRecord::RecordInvalid)
    expect(invoice.reload.status).to eq("paid")
  end
end
