# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScanClientDocumentJob, type: :job do
  it "does not relabel legacy files clean through the no-op adapter" do
    document = create(:client_document)
    described_class.perform_now(document.id)
    expect(document.reload.scan_status).to eq("not_scanned")
  end

  it "resumes preview generation after a real adapter returns clean" do
    document = create(:client_document, scan_status: "pending")
    adapter = double(scan: "clean")
    allow(ClientDocumentScanner).to receive(:adapter).and_return(adapter)
    expect { described_class.perform_now(document.id) }.to have_enqueued_job(GenerateClientDocumentPreviewJob).with(document.id)
    expect(document.reload.scan_status).to eq("clean")
  end
end
