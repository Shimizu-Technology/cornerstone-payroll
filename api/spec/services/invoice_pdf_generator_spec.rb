# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoicePdfGenerator do
  it "generates a PDF for an invoice" do
    invoice = create(:invoice, :with_line_item)

    pdf = described_class.new(invoice.reload).generate

    expect(pdf).to start_with("%PDF")
  end
end
