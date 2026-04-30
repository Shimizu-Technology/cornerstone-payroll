# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientDocumentUploadService do
  let(:company) { create(:company) }
  let(:user) { create(:user, company: company, role: "client") }
  let(:fixture_path) { Rails.root.join("spec/fixtures/files/client_portal_upload.txt") }

  before do
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT)
  end

  it "cleans up uploaded storage objects when document creation fails after upload" do
    upload = Rack::Test::UploadedFile.new(fixture_path, "text/plain")
    service = described_class.new(
      company_id: company.id,
      current_user: user,
      params: {
        file: upload,
        category: "invalid_category"
      }
    )
    storage_key = "client_documents/company_#{company.id}/failed-upload.txt"
    allow(service).to receive(:build_file_key).and_return(storage_key)

    expect { service.upload! }.to raise_error(ActiveRecord::RecordInvalid)
    expect(R2StorageService.new.download(storage_key)).to be_nil
  end
end
