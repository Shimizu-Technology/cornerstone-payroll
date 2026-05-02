# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceAiPreviewService do
  it "returns a deterministic fallback preview when no AI key is configured" do
    company = create(:company)
    user = create(:user, company: company)
    recipient = create(:invoice_recipient, company: company, name: "Shimizu Technology", payment_terms: "Due on receipt")
    session = create(:invoice_chat_session, company: company, created_by: user, updated_by: user)

    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return(nil)

    preview = described_class.new(
      company: company,
      user: user,
      session: session,
      message: "Invoice Shimizu Technology $1,000 for accounting service"
    ).call

    expect(preview["status"]).to eq("preview")
    expect(preview["invoice_recipient_id"]).to eq(recipient.id)
    expect(preview["line_items"].first).to include(
      "description" => "Accounting service",
      "quantity" => 1.0,
      "rate" => 1000.0
    )
    expect(preview["payment_terms"]).to eq("Due on receipt")
  end
end
