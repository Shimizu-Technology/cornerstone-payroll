# frozen_string_literal: true

require "rails_helper"

RSpec.describe "QuickBooks original stubs", type: :request do
  let(:company) { create(:company, historical_payroll_enabled: true) }
  let(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company, first_name: "Jesse", last_name: "Example") }
  let!(:check) { create(:historical_paycheck, employee: employee, source_employee_name: "Example, Jesse") }
  let(:storage) { instance_double(R2StorageService, upload: true) }
  let(:root) { "/api/v1/admin/quickbooks_stub_upload" }

  before do
    allow_any_instance_of(Api::V1::Admin::QuickbooksStubUploadsController).to receive(:current_user).and_return(admin)
    allow(CompanyFeatures).to receive(:for).with(company).and_return(instance_double(CompanyFeatures, employee_portal_feature?: true))
    allow(R2StorageService).to receive(:new).and_return(storage)
  end

  def pdf(*pages)
    bytes = Prawn::Document.new do |pdf|
      pages.each_with_index do |lines, index|
        pdf.start_new_page if index.positive?
        pdf.text(lines)
      end
    end.render

    Rack::Test::UploadedFile.new(StringIO.new(bytes), "application/pdf", original_filename: "source.pdf")
  end

  def submit(action, upload:, tokens: [])
    post "#{root}/#{action}", params: { upload: upload, review_tokens: tokens },
      headers: { "X-Company-Id" => company.id.to_s }
  end

  def page_text
    "Employee: Jesse Example\nPay Date: 01/20/2026\nNet Pay: $900.00"
  end

  it "previews only unambiguous matches and freezes only the reviewed page, idempotently" do
    unrelated = "Employee: Different Name\nPay Date: 01/20/2026\nNet Pay: $900.00"
    expect { submit("preview", upload: pdf(page_text, unrelated)) }.not_to change(EmployeeDocument, :count)
    expect(response).to have_http_status(:ok), response.body
    pages = response.parsed_body.fetch("data")
    expect(pages).to match([
      include("page" => 1, "status" => "matched", "employee_name" => employee.full_name, "check_number" => nil),
      { "page" => 2, "status" => "unmatched" }
    ])
    token = pages.first.fetch("review_token")
    expect { submit("confirm", upload: pdf(page_text, unrelated), tokens: [ token ]) }.to change(EmployeeDocument, :count).by(1)
    expect(response).to have_http_status(:ok), response.body
    doc = EmployeeDocument.find_by!(historical_paycheck: check)
    expect(storage).to have_received(:upload).with(doc.storage_key, satisfy do |bytes|
      output = PDF::Reader.new(StringIO.new(bytes))
      output.page_count == 1 && output.page(1).text.include?("Jesse Example") && Digest::SHA256.hexdigest(bytes) == doc.sha256
    end, content_type: "application/pdf").once
    expect { submit("confirm", upload: pdf(page_text, unrelated), tokens: [ token ]) }.not_to change(EmployeeDocument, :count)
    expect(response).to have_http_status(:ok), response.body
    expect(AuditLog.where(company: company).pluck(:action)).to include(
      "quickbooks_stub_uploads#upload", "quickbooks_stub_uploads#preview",
      "quickbooks_stub_uploads#confirm_requested", "quickbooks_stub_uploads#confirmed"
    )
  end

  it "blocks a full SSN and a substituted upload before storage" do
    submit("preview", upload: pdf(page_text))
    token = response.parsed_body.fetch("data").first.fetch("review_token")

    with_ssn = "#{page_text}\nSSN: 111-22-3333"
    submit("preview", upload: pdf(with_ssn, "#{page_text}\nSSN: 111223333"))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to eq([
      { "page" => 1, "status" => "full_ssn" }, { "page" => 2, "status" => "full_ssn" }
    ])
    expect { submit("confirm", upload: pdf(with_ssn), tokens: [ token ]) }.not_to change(EmployeeDocument, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(storage).not_to have_received(:upload)
  end

  it "uses a supplied check number to resolve same-day same-amount checks" do
    check.update_columns(check_number: "120")
    create(:historical_paycheck, employee: employee, check_number: "124")
    submit("preview", upload: pdf(page_text, "#{page_text}\nCheck Number: 124"))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to match([
      { "page" => 1, "status" => "ambiguous" }, include("page" => 2, "status" => "matched", "check_number" => "124")
    ])
  end

  it "does not surface a malformed historical link to an employee of another company" do
    check.update_columns(employee_id: create(:employee, first_name: "Jesse", last_name: "Example").id)
    submit("preview", upload: pdf(page_text))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to eq([ { "page" => 1, "status" => "unmatched" } ])
  end

  it "rejects staff without the historical import permission" do
    admin.update!(role: "accountant")
    submit("preview", upload: pdf(page_text))
    expect(response).to have_http_status(:forbidden)
  end
end
