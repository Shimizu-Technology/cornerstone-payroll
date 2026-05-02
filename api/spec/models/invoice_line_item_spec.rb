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
end
