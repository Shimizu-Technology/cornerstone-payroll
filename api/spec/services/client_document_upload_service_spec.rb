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

  it "uploads before taking the company lock for a readiness attachment" do
    employee = create(:employee, company: company)
    requirement = create(:employee_document_requirement, company: company, employee: employee)
    upload = Rack::Test::UploadedFile.new(fixture_path, "text/plain")
    storage = instance_double(R2StorageService)
    allow(R2StorageService).to receive(:new).and_return(storage)
    expect(storage).to receive(:upload).ordered
    expect(Company).to receive(:lock).ordered.and_call_original

    result = described_class.new(
      company_id: company.id,
      current_user: user,
      params: {
        file: upload,
        employee_id: employee.id,
        requirement_id: requirement.id,
        category: "employee_onboarding"
      }
    ).upload!

    expect(result.document_requirement.reload).to have_attributes(status: "received")
  end

  it "deletes an uploaded object if the readiness item changes before attachment" do
    employee = create(:employee, company: company)
    requirement = create(:employee_document_requirement, company: company, employee: employee)
    upload = Rack::Test::UploadedFile.new(fixture_path, "text/plain")
    storage = instance_double(R2StorageService)
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:upload) { requirement.destroy! }
    expect(storage).to receive(:delete).once

    service = described_class.new(
      company_id: company.id,
      current_user: user,
      params: {
        file: upload,
        employee_id: employee.id,
        requirement_id: requirement.id,
        category: "employee_onboarding"
      }
    )

    expect { service.upload! }.to raise_error(ActiveRecord::RecordNotFound, "Document requirement not found")
    expect(ClientDocument.where(employee: employee)).to be_empty
  end
end
