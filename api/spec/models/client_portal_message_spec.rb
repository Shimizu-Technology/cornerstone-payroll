# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientPortalMessage, type: :model do
  it "marks the author side read and broadcasts through the portal thread" do
    company = create(:company)
    staff = create(:user, company: company, role: "accountant")
    thread = create(:client_portal_thread, company: company, created_by: staff)

    allow(ClientPortalThreadChannel).to receive(:broadcast_thread)

    message = described_class.create!(
      client_portal_thread: thread,
      company: company,
      author: staff,
      body: "The register is ready for review."
    )

    thread.reload
    expect(thread.last_message_at.to_i).to eq(message.created_at.to_i)
    expect(thread.staff_last_read_at.to_i).to eq(message.created_at.to_i)
    expect(thread.client_last_read_at).to be_nil
    expect(ClientPortalThreadChannel).to have_received(:broadcast_thread).with(thread, event: "message_created")
  end

  it "rejects documents from another company" do
    company = create(:company)
    other_company = create(:company)
    thread = create(:client_portal_thread, company: company)
    document = create(:client_document, company: other_company)

    message = described_class.new(
      client_portal_thread: thread,
      company: company,
      client_document: document
    )

    expect(message).not_to be_valid
    expect(message.errors[:client_document]).to include("must belong to the same company")
  end
end
