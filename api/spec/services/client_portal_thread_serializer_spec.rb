# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientPortalThreadSerializer do
  it "redacts internal preview errors from attached documents" do
    company = create(:company)
    user = create(:user, company: company, role: "client")
    document = create(:client_document,
      company: company,
      uploaded_by: user,
      preview_status: "failed",
      preview_error: "/tmp/libreoffice/convert failed with stack trace")
    thread = create(:client_portal_thread, company: company, created_by: user)
    create(:client_portal_message,
      client_portal_thread: thread,
      company: company,
      author: user,
      client_document: document,
      body: nil)

    payload = described_class.new(current_user: user).thread(thread, include_messages: true)
    attached_document = payload.fetch(:messages).first.fetch(:document)

    expect(attached_document.fetch(:preview_error)).to eq("Preview is unavailable for this file.")
  end
end
