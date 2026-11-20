# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceLineItem, type: :model do
  it "calculates amount from quantity and rate" do
    item = build(:invoice, :with_line_item).line_items.first
    item.quantity = 3.5
    item.rate = 100

    expect(item).to be_valid
    expect(item.amount).to eq(350)
  end
  it "flags zero reimbursements even when a caller supplies a false review flag" do
    invoice = create(:invoice, :with_line_item)
    line = invoice.line_items.create!(description: "Tax payment", quantity: 1, line_kind: "reimbursement", reimbursement_review_required: false)
    expect(line).to have_attributes(rate: 0.to_d, reimbursement_review_required: true)
    # Legacy unflagged rows must also be refused by the issue guard.
    line.update_column(:reimbursement_review_required, false)
    expect { invoice.reload.issue!(actor: nil) }.to raise_error(ActiveRecord::RecordInvalid, /reimbursement/)
    line.update!(rate: 50)
    expect(line.reload.reimbursement_review_required).to be(false)
    invoice.reload.issue!(actor: nil)
    expect(invoice.reload).to be_open
  end
end
