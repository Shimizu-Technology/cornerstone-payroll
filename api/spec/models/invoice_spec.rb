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
    invoice = create(:invoice, :with_line_item, company: recipient.company, invoice_recipient: recipient, invoice_number: nil)

    expect(invoice.invoice_number).to match(/\ACS-\d{4}-\d{4}\z/)
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
