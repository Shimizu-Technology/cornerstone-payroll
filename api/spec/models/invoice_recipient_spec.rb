# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceRecipient, type: :model do
  it "normalizes blank optional fields" do
    recipient = build(:invoice_recipient, email: " ", address: " ", template_type: nil)

    expect(recipient).to be_valid
    expect(recipient.email).to be_nil
    expect(recipient.address).to be_nil
    expect(recipient.template_type).to eq("standard")
  end
end
