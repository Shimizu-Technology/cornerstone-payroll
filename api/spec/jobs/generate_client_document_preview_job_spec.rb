# frozen_string_literal: true

require "rails_helper"

RSpec.describe GenerateClientDocumentPreviewJob, type: :job do
  # Spreadsheets preview as sheet tables; Word files still use the converter.
  let(:document) do
    create(:client_document, file_name: "notes.docx", file_key: "client_documents/test/notes.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
  end
  let(:generator) { instance_double(ClientDocumentPreviewGenerator) }

  before { allow(ClientDocumentPreviewGenerator).to receive(:new).and_return(generator) }

  it "fails its processing state when the generator's second usability check blocks" do
    allow(generator).to receive(:generate!) do
      document.update!(archived_at: Time.current)
      document.ensure_usable_for!(:preview)
    end
    described_class.perform_now(document.id)
    expect(document.reload).to have_attributes(preview_status: "failed", preview_error: "This file has been archived. Contact Cornerstone if you need it.")
  end

  it "preserves a concurrent status update when generation is blocked" do
    allow(generator).to receive(:generate!) do
      document.update!(preview_status: "ready", preview_file_key: "new-preview.pdf")
      raise ClientDocumentScanner::Blocked, "Safety check changed"
    end
    described_class.perform_now(document.id)
    expect(document.reload.preview_status).to eq("ready")
  end

  it "does not change preview state when blocked before starting processing" do
    document.update!(scan_status: "infected")
    described_class.perform_now(document.id)
    expect(document.reload.preview_status).to eq("pending")
  end
end
