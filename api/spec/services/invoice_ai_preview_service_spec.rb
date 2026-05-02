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

  it "drops zero-quantity AI line items before marking a preview ready" do
    company = create(:company)
    user = create(:user, company: company)
    recipient = create(:invoice_recipient, company: company, name: "Shimizu Technology")
    session = create(:invoice_chat_session, company: company, created_by: user, updated_by: user)
    response = {
      "status" => "preview",
      "message" => "Ready for review.",
      "invoice_recipient_id" => recipient.id,
      "line_items" => [
        { "description" => "Accounting service", "quantity" => 0, "rate" => 100 }
      ]
    }

    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test-key")
    allow(HTTParty).to receive(:post).and_return(
      instance_double("HTTParty::Response", success?: true, dig: response.to_json)
    )

    preview = described_class.new(
      company: company,
      user: user,
      session: session,
      message: "Invoice Shimizu Technology"
    ).call

    expect(preview["status"]).to eq("clarification_needed")
    expect(preview["line_items"]).to be_empty
  end

  it "sends image attachments as multimodal image_url content" do
    company = create(:company)
    user = create(:user, company: company)
    recipient = create(:invoice_recipient, company: company, name: "Shimizu Technology")
    session = create(:invoice_chat_session, company: company, created_by: user, updated_by: user)
    response = {
      "status" => "preview",
      "message" => "Ready for review.",
      "invoice_recipient_id" => recipient.id,
      "line_items" => [
        { "description" => "Accounting service", "quantity" => 1, "rate" => 100 }
      ]
    }
    request_body = nil

    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test-key")
    storage = instance_double(R2StorageService, download: "fake image bytes")
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(HTTParty).to receive(:post) do |_url, options|
      request_body = JSON.parse(options.fetch(:body))
      instance_double("HTTParty::Response", success?: true, dig: response.to_json)
    end

    described_class.new(
      company: company,
      user: user,
      session: session,
      message: "Invoice from the attached statement",
      image_urls: [ "invoice-assistant/company-1/session-1/upload.jpg" ]
    ).call

    user_content = request_body.dig("messages", 1, "content")
    expect(user_content).to be_an(Array)
    expect(user_content.first).to include("type" => "text")
    expect(user_content.second).to include(
      "type" => "image_url",
      "image_url" => include("url" => a_string_starting_with("data:image/jpeg;base64,"))
    )
  end
end
