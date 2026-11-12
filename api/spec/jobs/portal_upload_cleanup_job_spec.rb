# frozen_string_literal: true

require "rails_helper"

RSpec.describe PortalUploadCleanupJob, type: :job do
  it "reaches a newer cleanup when more than a batch of older ones keep failing" do
    company = create(:company)
    stuck = Array.new(100) { |i| PortalUploadCleanup.create!(company_id: company.id, file_key: "stuck-#{i}", attempts: 5) }
    newer = PortalUploadCleanup.create!(company_id: company.id, file_key: "newer")
    storage = instance_double(R2StorageService)
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:delete).and_raise(R2StorageService::UploadError, "outage")
    allow(storage).to receive(:delete).with("newer").and_return(nil)

    described_class.perform_now

    expect(newer.reload.completed_at).to be_present
    expect(stuck.map { |cleanup| cleanup.reload.attempts }.count(6)).to eq(99)
  end
end
