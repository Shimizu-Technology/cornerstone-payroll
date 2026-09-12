# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollImports", type: :request do
  let!(:company) { create(:company, payroll_intake_source_types: [ "mosa_revel" ]) }
  let!(:admin_user) { create(:user, company: company, role: "admin") }
  let!(:pay_period) { create(:pay_period, company: company, status: "draft") }
  let!(:included_employee) { create(:employee, company: company, first_name: "Avery", last_name: "Example") }
  let!(:excluded_employee) { create(:employee, company: company, first_name: "Casey", last_name: "Fixture") }

  before do
    allow_any_instance_of(Api::V1::Admin::PayrollImportsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::PayrollImportsController).to receive(:current_company_id).and_return(company.id)
  end

  describe "GET /api/v1/admin/pay_periods/:id/supplemental_template" do
    it "downloads the exact period template with stable employee IDs" do
      get "/api/v1/admin/pay_periods/#{pay_period.id}/supplemental_template"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
      expect(response.headers.fetch("Content-Disposition")).to include("payroll-changes-#{pay_period.end_date.iso8601}.xlsx")

      file = Tempfile.new([ "downloaded-mosa-template", ".xlsx" ])
      file.binmode
      file.write(response.body)
      file.close
      workbook = Roo::Spreadsheet.open(file.path)
      expect(workbook.sheet(PayrollImport::MosaSupplementalTemplate::EMPLOYEE_CHANGES_SHEET).column(1)).to include(included_employee.id)
    ensure
      file&.unlink
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/preview_import" do
    it "retains and returns an integrity-verified Revel source package" do
      CompanyWorkweek.create!(
        company: company,
        starts_on_weekday: pay_period.start_date.wday,
        starts_at_minutes: 0,
        timezone: "Pacific/Guam",
        effective_on: pay_period.start_date,
        source: "operator_confirmed",
        confirmation_status: "confirmed",
        confirmed_by: admin_user,
        confirmed_at: Time.current,
        notes: "Confirmed for request test"
      )
      storage = Class.new do
        def initialize
          @objects = {}
        end

        def upload(key, data, content_type:)
          @objects[key] = { data: data, content_type: content_type }
        end

        def download_with_limit(key, max_bytes:)
          @objects.fetch(key).fetch(:data).byteslice(0, max_bytes)
        end

        def delete(key)
          @objects.delete(key)
        end
      end.new
      allow(R2StorageService).to receive(:new).and_return(storage)

      pdf_path = build_revel_pdf(
        [ { name: "Example, Avery", regular_hours: 40, overtime_hours: 2, regular_pay: 9_999 } ],
        period_start: pay_period.start_date,
        period_end: pay_period.end_date
      )
      workbook_file = Tempfile.new([ "mosa-changes", ".xlsx" ])
      workbook_file.binmode
      workbook_file.write(PayrollImport::MosaSupplementalTemplate.new(pay_period).generate)
      workbook_file.close

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import",
           params: {
             pdf_file: Rack::Test::UploadedFile.new(pdf_path, "application/pdf", true, original_filename: "payroll_#{pay_period.start_date}_to_#{pay_period.end_date}.pdf"),
             excel_file: Rack::Test::UploadedFile.new(workbook_file.path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
           }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("source_package")).to include(
        "package_revision" => 1,
        "verified_source_count" => 2,
        "source_count" => 2
      )
      expect(response.parsed_body.dig("preview", "matched")).to contain_exactly(include(
        "employee_id" => included_employee.id,
        "regular_hours" => 40.0,
        "overtime_hours" => 2.0,
        "pay_rate" => included_employee.pay_rate.to_f
      ))
      expect(PayrollImportRecord.last.payroll_intake_session.documents.in_package_order.map(&:source_role)).to eq([ "revel_hours", "supplemental_workbook" ])
    ensure
      workbook_file&.unlink
    end

    it "persists the reviewed tip payout mode with the server preview" do
      source_package = create(
        :payroll_intake_session,
        company: company,
        pay_period: pay_period,
        source_type: "mosa_revel",
        source_label: PayrollIntake::Adapters::MosaRevel::SOURCE_LABEL,
        parser_version: PayrollIntake::Adapters::MosaRevel::PARSER_VERSION,
        evidence_snapshot: {
          "preview" => {
            "pdf_count" => 0,
            "excel_count" => 0,
            "duplicate_employee_matches" => [],
            "low_confidence_matches" => []
          }
        }
      )
      preview_service = instance_double(PayrollIntake::PreviewService, call: { session: source_package, duplicate: false })
      allow(PayrollIntake::PreviewService).to receive(:new).and_return(preview_service)

      Tempfile.create([ "hours", ".pdf" ]) do |file|
        upload = Rack::Test::UploadedFile.new(file.path, "application/pdf")
        post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import",
             params: { pdf_file: upload, tips_paid_out_from_tips: "true" }
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("preview", "tips_paid_out_from_tips")).to be(true)
      expect(response.parsed_body.dig("source_package", "package_id")).to eq(source_package.package_id)
      expect(PayrollImportRecord.last.raw_data.fetch("tips_paid_out_from_tips")).to be(true)
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/apply_import" do
    def create_preview!(raw_data: {}, unmatched_pdf_names: [])
      source_package = create(
        :payroll_intake_session,
        company: company,
        pay_period: pay_period,
        source_type: "mosa_revel",
        source_label: PayrollIntake::Adapters::MosaRevel::SOURCE_LABEL,
        parser_version: PayrollIntake::Adapters::MosaRevel::PARSER_VERSION
      )
      PayrollImportRecord.create!(
        pay_period: pay_period,
        payroll_intake_session: source_package,
        status: "previewed",
        raw_data: {
          tips_paid_out_from_tips: false,
          unmatched_excel_names: [],
          duplicate_employee_matches: [],
          low_confidence_matches: []
        }.merge(raw_data),
        unmatched_pdf_names: unmatched_pdf_names,
        matched_data: [
          { employee_id: included_employee.id, regular_hours: 40.0, total_tips: 25.0 },
          { employee_id: excluded_employee.id, regular_hours: 10.0, total_tips: 0.0 }
        ]
      )
    end

    it "refuses to apply when any Revel or workbook source row is unresolved" do
      import = create_preview!(raw_data: { unmatched_excel_names: [ "Missing Worker" ] })

      expect(PayrollImport::ImportService).not_to receive(:new)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: { import_id: import.id },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to match(/Resolve every unmatched or duplicate source row/)
      expect(response.parsed_body.fetch("details")).to include(
        "unmatched_names" => [ "Missing Worker" ],
        "duplicate_matches" => []
      )
      expect(import.reload.status).to eq("previewed")
    end

    it "refuses to apply a source package with blocking row errors" do
      import = create_preview!
      create(
        :payroll_intake_row,
        payroll_intake_session: import.payroll_intake_session,
        employee: included_employee,
        source_employee_name: included_employee.full_name,
        validation_errors: [
          { code: "doubletime_not_supported", message: "Double-time requires review", severity: "error" }
        ]
      )

      expect(PayrollImport::ImportService).not_to receive(:new)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: { import_id: import.id },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to match(/Resolve every blocked source row/)
      expect(response.parsed_body.dig("details", "blocked_rows")).to contain_exactly(
        include("source_employee_name" => included_employee.full_name)
      )
      expect(import.reload.status).to eq("previewed")
    end

    it "refuses to apply when a retained source no longer matches its fingerprint" do
      import = create_preview!
      import.payroll_intake_session.update!(status: "draft")
      import.payroll_intake_session.documents.create!(
        document_type: "pasted_text",
        source_role: "supporting_document",
        position: 0,
        text_content: "tampered",
        byte_size: "original".bytesize,
        sha256: Digest::SHA256.hexdigest("original"),
        verification_status: "verified",
        verified_at: Time.current
      )
      import.payroll_intake_session.update!(status: "previewed")

      expect(PayrollImport::ImportService).not_to receive(:new)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: { import_id: import.id },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to match(/fingerprint/)
      expect(import.reload.status).to eq("previewed")
      expect(import.payroll_intake_session.documents.first.reload.verification_status).to eq("failed")
    end

    it "requires explicit confirmation of suggested name matches" do
      import = create_preview!(
        raw_data: {
          low_confidence_matches: [
            { source: "Revel hours", source_name: "Exmaple, Avery", employee_id: included_employee.id }
          ]
        }
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: { import_id: import.id },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to match(/Review and confirm/)
      expect(response.parsed_body.dig("details", "low_confidence_matches")).to contain_exactly(
        include("source_name" => "Exmaple, Avery")
      )
      expect(import.reload.status).to eq("previewed")
    end

    it "applies the immutable server preview and only accepts browser-side exclusions" do
      import = create_preview!(
        raw_data: {
          low_confidence_matches: [
            { source: "Revel hours", source_name: "Exmaple, Avery", employee_id: included_employee.id }
          ]
        }
      )
      service = instance_double(PayrollImport::ImportService)

      expect(PayrollImport::ImportService).to receive(:new).with(pay_period, actor: admin_user).and_return(service)
      expect(service).to receive(:apply!).with(
        matched: [ { employee_id: included_employee.id, regular_hours: 40.0, total_tips: 25.0 } ],
        force_overwrite: false,
        tips_paid_out_from_tips: false
      ).and_return(success: [], skipped: [], errors: [])

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: import.id,
             excluded_employee_ids: [ excluded_employee.id ],
             acknowledge_low_confidence_matches: true,
             tips_paid_out_from_tips: true,
             matched: [
               { employee_id: included_employee.id, regular_hours: 9_999, total_tips: 9_999 }
             ]
           },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(import.reload.status).to eq("applied")
      expect(import.payroll_intake_session.reload).to have_attributes(
        status: "applied",
        reviewed_by: admin_user,
        applied_by: admin_user
      )
    end

    it "refuses an API request that excludes every matched employee" do
      import = create_preview!

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: import.id,
             excluded_employee_ids: [ included_employee.id, excluded_employee.id ]
           },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq("Keep at least one matched employee in the import.")
      expect(response.parsed_body.fetch("details")).to eq("remaining_matched_rows" => 0)
      expect(import.reload.status).to eq("previewed")
    end

    it "uses the persisted tip payout mode even when apply submits a different value" do
      import = create_preview!(raw_data: { tips_paid_out_from_tips: true })
      service = instance_double(PayrollImport::ImportService)

      expect(PayrollImport::ImportService).to receive(:new).with(pay_period, actor: admin_user).and_return(service)
      expect(service).to receive(:apply!).with(
        matched: import.matched_data.map(&:deep_symbolize_keys),
        force_overwrite: false,
        tips_paid_out_from_tips: true
      ).and_return(success: [], skipped: [], errors: [])

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: { import_id: import.id, tips_paid_out_from_tips: false },
           as: :json

      expect(response).to have_http_status(:ok)
    end

    it "rolls back every payroll item when any imported row fails" do
      import = create_preview!
      service = instance_double(PayrollImport::ImportService)
      allow(PayrollImport::ImportService).to receive(:new).with(pay_period, actor: admin_user).and_return(service)
      allow(service).to receive(:apply!) do
        PayrollItem.create!(
          pay_period: pay_period,
          employee: included_employee,
          employment_type: included_employee.employment_type,
          pay_rate: included_employee.pay_rate,
          hours_worked: 40,
          import_source: "mosa_revel"
        )
        {
          success: [ { employee_id: included_employee.id, name: included_employee.full_name } ],
          skipped: [],
          errors: [ { employee_id: excluded_employee.id, name: excluded_employee.full_name, error: "Invalid loan setup" } ]
        }
      end

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: { import_id: import.id },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to match(/Nothing was imported/)
      expect(pay_period.payroll_items.reload).to be_empty
      expect(import.reload).to have_attributes(status: "previewed", validation_errors: [ "Invalid loan setup" ])
      expect(import.payroll_intake_session.reload.status).to eq("previewed")
    end
  end
end
