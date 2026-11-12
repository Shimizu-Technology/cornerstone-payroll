# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientDocumentScanRecoveryJob, type: :job do
  include ActiveJob::TestHelper

  before do
    allow(ClientDocumentScanner).to receive(:adapter).and_return(double(initial_status: "pending", scan: "clean"))
  end

  it "recovers stale scans after worker termination and skips recent or terminal states" do
    stale = create(:client_document, scan_status: "pending", updated_at: 16.minutes.ago)
    recent = create(:client_document, scan_status: "pending")
    terminal = %w[clean infected error not_scanned].map { |status| create(:client_document, scan_status: status, updated_at: 1.hour.ago) }
    clear_enqueued_jobs
    expect { described_class.perform_now }.to have_enqueued_job(ScanClientDocumentJob).with(stale.id).exactly(:once)
    expect(enqueued_jobs.map { |job| job[:args].first }).not_to include(recent.id, *terminal.map(&:id))
    clear_enqueued_jobs
    expect { described_class.perform_now }.not_to have_enqueued_job(ScanClientDocumentJob)
  end

  it "bounds each sweep and backs off when enqueue fails" do
    stub_const("ClientDocumentScanRecoveryJob::BATCH_SIZE", 1)
    first = create(:client_document, scan_status: "pending", updated_at: 1.hour.ago)
    second = create(:client_document, scan_status: "pending", updated_at: 30.minutes.ago)
    allow(ScanClientDocumentJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError)
    expect { described_class.perform_now }.not_to raise_error
    expect(first.reload.updated_at).to be > 1.minute.ago
    expect(second.reload.updated_at).to be < 15.minutes.ago
    expect(first.scan_status).to eq("pending")
  end

  it "does no work with the current no-scanner adapter" do
    create(:client_document, scan_status: "pending", updated_at: 1.hour.ago)
    allow(ClientDocumentScanner).to receive(:adapter).and_return(ClientDocumentScanner::Noop.new)
    clear_enqueued_jobs
    expect { described_class.perform_now }.not_to have_enqueued_job(ScanClientDocumentJob)
  end

  it "is registered on the production scheduler" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production").fetch("recover_pending_client_document_scans")
    expect(schedule).to include("class" => described_class.name, "schedule" => "every 5 minutes")
  end
end
