# frozen_string_literal: true

require "rails_helper"

# Sheet previews and import-review source previews use exactly the access
# rules of downloading the same file: staff need that client's company, and
# client users only see their own company's client-visible files.
RSpec.describe "Spreadsheet and import source previews", type: :request do
  include RevelPdfFixtureHelper

  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, name: "Preview Bistro QA", payroll_intake_source_types: [ "mosa_revel" ]) }
  let(:other_company) { create(:company, organization: organization, name: "Other Preview QA") }
  let(:staff_user) { create(:user, company: company, organization: organization, role: "manager", platform_owner: false) }
  let(:client_user) { create(:user, company: company, organization: organization, role: "client", platform_owner: false) }
  let(:other_client) { create(:user, company: other_company, organization: organization, role: "client", platform_owner: false) }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }
  let(:workbook_bytes) do
    preview_workbook({
      "TIPS" => %(<row r="1">#{preview_text_cell('A1', 'Employee')}#{preview_text_cell('B1', 'Tips')}</row>) +
        %(<row r="2">#{preview_text_cell('A2', 'Ava Cruz')}<c r="B2"><f>40+2.5</f><v>42.5</v></c></row>),
      "LOANS" => %(<row r="1">#{preview_text_cell('A1', 'Loan')}</row>)
    })
  end

  def act_as(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(user.id)
  end

  def stored_document(owner_company, file_name:, bytes:, visible: true, content_type: ClientDocumentFileValidator::TYPES.fetch(File.extname(file_name).delete(".")))
    document = create(:client_document, company: owner_company, uploaded_by: staff_user, title: file_name, file_name: file_name,
      content_type: content_type, file_size: bytes.bytesize, visible_to_client: visible, scan_status: "clean",
      preview_status: ClientDocument.initial_preview_status_for(Struct.new(:original_filename).new(file_name)),
      file_key: "client_documents/company_#{owner_company.id}/#{SecureRandom.hex(4)}/#{file_name}")
    R2StorageService.new.upload(document.file_key, bytes, content_type: content_type)
    document
  end

  before do
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT)
    CompanyAssignment.create!(user: staff_user, company: company)
    CompanyAssignment.create!(user: client_user, company: company)
    CompanyAssignment.create!(user: other_client, company: other_company)
  end

  describe "client document previews" do
    let!(:workbook) { stored_document(company, file_name: "tips.xlsx", bytes: workbook_bytes) }
    let!(:other_workbook) { stored_document(other_company, file_name: "other.xlsx", bytes: workbook_bytes) }

    it "shows staff an .xlsx as sheet tables with computed values and records the access" do
      act_as(staff_user)
      expect(ClientDocumentPreviewGenerator).not_to receive(:new)

      get "/api/v1/admin/client_documents/#{workbook.id}/preview", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      expect(response.headers["Cache-Control"]).to include("no-store")
      preview = response.parsed_body.fetch("sheet_preview")
      expect(preview.fetch("sheets").map { |sheet| sheet.fetch("name") }).to eq(%w[TIPS LOANS])
      expect(preview.dig("sheets", 0, "rows", 1, "cells")).to eq([ "Ava Cruz", "42.5" ])
      expect(AuditLog.where(action: "portal_documents#preview", record_type: "client_documents", record_id: workbook.id)).to exist

      get "/api/v1/admin/client_documents", headers: headers
      listed = response.parsed_body.fetch("data").find { |row| row.fetch("id") == workbook.id }
      expect(listed).to include("preview_available" => true, "preview_status" => "not_required")
    end

    it "shows a client their own company's workbook and CSV" do
      csv = stored_document(company, file_name: "hours.csv", bytes: "name,hours\nAva,40\n")
      act_as(client_user)

      get "/api/v1/client/documents/#{workbook.id}/preview", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("sheet_preview", "sheets", 0, "name")).to eq("TIPS")

      get "/api/v1/client/documents/#{csv.id}/preview", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("sheet_preview", "sheets", 0, "rows", 1, "cells")).to eq(%w[Ava 40])
    end

    it "denies staff another company's workbook" do
      act_as(staff_user)

      get "/api/v1/admin/client_documents/#{other_workbook.id}/preview", headers: headers
      expect(response).to have_http_status(:not_found)

      get "/api/v1/admin/client_documents/#{other_workbook.id}/preview", headers: { "X-Company-Id" => other_company.id.to_s }
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("sheet_preview")
    end

    it "keeps clients to their own company's client-visible files and out of the staff endpoint" do
      hidden = stored_document(company, file_name: "staff-only.xlsx", bytes: workbook_bytes, visible: false)
      act_as(client_user)

      get "/api/v1/client/documents/#{other_workbook.id}/preview", headers: headers
      expect(response).to have_http_status(:not_found)

      get "/api/v1/client/documents/#{other_workbook.id}/preview", headers: { "X-Company-Id" => other_company.id.to_s }
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/client/documents/#{hidden.id}/preview", headers: headers
      expect(response).to have_http_status(:not_found)

      get "/api/v1/admin/client_documents/#{workbook.id}/preview", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("sheet_preview")
    end

    it "refuses staff on the client endpoint" do
      act_as(staff_user)

      get "/api/v1/client/documents/#{workbook.id}/preview", headers: headers

      expect(response).to have_http_status(:forbidden)
    end

    it "caps large sheets and reports the truncation" do
      large = stored_document(company, file_name: "large.xlsx",
        bytes: preview_workbook({ "Big" => preview_grid(rows: SpreadsheetPreview::MAX_ROWS + 1, columns: SpreadsheetPreview::MAX_COLUMNS + 1) }))
      act_as(staff_user)

      get "/api/v1/admin/client_documents/#{large.id}/preview", headers: headers

      expect(response).to have_http_status(:ok)
      sheet = response.parsed_body.dig("sheet_preview", "sheets", 0)
      expect(sheet.fetch("rows").length).to eq(SpreadsheetPreview::MAX_ROWS)
      expect(sheet.fetch("columns")).to eq(SpreadsheetPreview::MAX_COLUMNS)
      expect(sheet).to include("truncated_rows" => true, "truncated_columns" => true)
      expect(response.parsed_body.dig("sheet_preview", "limits")).to eq("sheets" => 10, "rows" => 500, "columns" => 50)
    end

    it "explains a corrupt workbook instead of failing" do
      corrupt = stored_document(company, file_name: "corrupt.xlsx", bytes: "PK\x03\x04this is not a workbook".b)
      act_as(client_user)

      get "/api/v1/client/documents/#{corrupt.id}/preview", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("sheet_preview" => nil)
      expect(response.parsed_body.fetch("sheet_preview_unavailable")).to include("could not be read")
      expect(AuditLog.where(action: "portal_documents#preview", record_type: "client_documents", record_id: corrupt.id)).not_to exist
    end
  end

  describe "import review source previews" do
    let!(:pay_period) { create(:pay_period, company: company, status: "draft") }
    let!(:employee) { create(:employee, company: company, first_name: "Avery", last_name: "Example") }
    let(:storage) do
      Class.new do
        def initialize = @objects = {}
        def upload(key, data, content_type:) = @objects[key] = { data: data, content_type: content_type }
        def download_with_limit(key, max_bytes:) = @objects.fetch(key).fetch(:data).byteslice(0, max_bytes)
        def delete(key) = @objects.delete(key)
      end.new
    end

    def preview_import!(workbook: true)
      CompanyWorkweek.create!(company: company, starts_on_weekday: pay_period.start_date.wday, starts_at_minutes: 0,
        timezone: "Pacific/Guam", effective_on: pay_period.start_date, source: "operator_confirmed",
        confirmation_status: "confirmed", confirmed_by: staff_user, confirmed_at: Time.current, notes: "Preview spec")
      pdf_path = build_revel_pdf([ { name: "Example, Avery", regular_hours: 40, overtime_hours: 0, regular_pay: 1 } ],
        period_start: pay_period.start_date, period_end: pay_period.end_date)
      params = { pdf_file: Rack::Test::UploadedFile.new(pdf_path, "application/pdf", true, original_filename: "revel-hours.pdf") }
      if workbook
        file = Tempfile.new([ "mosa-changes", ".xlsx" ])
        file.binmode
        file.write(PayrollImport::MosaSupplementalTemplate.new(pay_period).generate)
        file.close
        params[:excel_file] = Rack::Test::UploadedFile.new(file.path, ClientDocumentFileValidator::TYPES.fetch("xlsx"), true, original_filename: "changes.xlsx")
      end
      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: params, headers: headers
      expect(response).to have_http_status(:ok)
      response.parsed_body.fetch("source_package")
    end

    def source_preview_path(package, document)
      "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_intake_imports/#{package.fetch('id')}/documents/#{document.fetch('id')}/preview"
    end

    before { allow(R2StorageService).to receive(:new).and_return(storage) }

    it "lists the retained files and serves the PDF inline and the workbook as sheets" do
      act_as(staff_user)
      package = preview_import!
      documents = package.fetch("documents")
      expect(documents.map { |document| document.fetch("source_role") }).to eq(%w[revel_hours supplemental_workbook])
      pdf, workbook = documents

      get source_preview_path(package, pdf), headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.headers.fetch("Content-Disposition")).to include("inline")
      expect(response.body).to start_with("%PDF")

      get source_preview_path(package, workbook), headers: headers
      expect(response).to have_http_status(:ok)
      sheets = response.parsed_body.dig("sheet_preview", "sheets")
      expect(sheets.map { |sheet| sheet.fetch("name") }).to include(PayrollImport::MosaSupplementalTemplate::EMPLOYEE_CHANGES_SHEET)
      expect(AuditLog.where(action: "payroll_intake_imports#preview_source_document", record_id: package.fetch("id")).count).to eq(2)
    end

    it "lists only the PDF when no workbook was provided" do
      act_as(staff_user)
      package = preview_import!(workbook: false)

      expect(package.fetch("documents").map { |document| document.fetch("source_role") }).to eq(%w[revel_hours])
    end

    it "denies another company's staff and client users" do
      act_as(staff_user)
      package = preview_import!
      pdf = package.fetch("documents").first
      other_staff = create(:user, company: other_company, organization: organization, role: "manager", platform_owner: false)
      CompanyAssignment.create!(user: other_staff, company: other_company)

      act_as(other_staff)
      get source_preview_path(package, pdf), headers: { "X-Company-Id" => other_company.id.to_s }
      expect(response).to have_http_status(:not_found)
      get source_preview_path(package, pdf), headers: headers
      expect(response).to have_http_status(:forbidden)

      act_as(client_user)
      get source_preview_path(package, pdf), headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to start_with("%PDF")
    end

    it "does not expose a document from another import session" do
      act_as(staff_user)
      package = preview_import!
      foreign = create(:pay_period, company: company, status: "draft", start_date: pay_period.end_date + 1, end_date: pay_period.end_date + 14, pay_date: pay_period.pay_date + 14)

      get "/api/v1/admin/pay_periods/#{foreign.id}/payroll_intake_imports/#{package.fetch('id')}/documents/#{package.dig('documents', 0, 'id')}/preview", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
