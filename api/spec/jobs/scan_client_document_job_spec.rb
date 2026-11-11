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

  it "keeps the first finished result when a duplicate recovery scan finishes later" do
    document = create(:client_document, scan_status: "pending")
    adapter = double
    allow(adapter).to receive(:scan) do |document:, **|
      ClientDocument.where(id: document.id).update_all(scan_status: "clean") # the other scan finishes first
      raise Timeout::Error, "scanner timed out"
    end
    allow(ClientDocumentScanner).to receive(:adapter).and_return(adapter)

    expect { described_class.perform_now(document.id) }.to raise_error(Timeout::Error)
    expect(document.reload.scan_status).to eq("clean")
  end

  it "does not queue a second preview when another scan already recorded clean" do
    document = create(:client_document, scan_status: "pending")
    adapter = double
    allow(adapter).to receive(:scan) do |document:, **|
      ClientDocument.where(id: document.id).update_all(scan_status: "clean") # the other scan finishes first
      "clean"
    end
    allow(ClientDocumentScanner).to receive(:adapter).and_return(adapter)

    expect { described_class.perform_now(document.id) }.not_to have_enqueued_job(GenerateClientDocumentPreviewJob)
    expect(document.reload.scan_status).to eq("clean")
  end
end
