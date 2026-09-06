# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollImports", type: :request do
  let!(:company) { create(:company) }
  let!(:admin_user) { create(:user, company: company, role: "admin") }
  let!(:pay_period) { create(:pay_period, company: company, status: "draft") }
  let!(:included_employee) { create(:employee, company: company, first_name: "Avery", last_name: "Example") }
  let!(:excluded_employee) { create(:employee, company: company, first_name: "Casey", last_name: "Fixture") }

  before do
    allow_any_instance_of(Api::V1::Admin::PayrollImportsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::PayrollImportsController).to receive(:current_company_id).and_return(company.id)
  end

  describe "POST /api/v1/admin/pay_periods/:id/preview_import" do
    it "persists the reviewed tip payout mode with the server preview" do
      service = instance_double(PayrollImport::ImportService)
      preview = {
        matched: [],
        unmatched_pdf_names: [],
        unmatched_excel_names: [],
        duplicate_employee_matches: [],
        low_confidence_matches: [],
        pdf_count: 0,
        excel_count: 0,
        matched_count: 0,
        can_apply: true
      }

      expect(PayrollImport::ImportService).to receive(:new).with(pay_period, actor: admin_user).and_return(service)
      allow(service).to receive(:preview).and_return(preview)

      Tempfile.create([ "hours", ".pdf" ]) do |file|
        upload = Rack::Test::UploadedFile.new(file.path, "application/pdf")
        post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import",
             params: { pdf_file: upload, tips_paid_out_from_tips: "true" }
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("preview", "tips_paid_out_from_tips")).to be(true)
      expect(PayrollImportRecord.last.raw_data.fetch("tips_paid_out_from_tips")).to be(true)
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/apply_import" do
    def create_preview!(raw_data: {}, unmatched_pdf_names: [])
      PayrollImportRecord.create!(
        pay_period: pay_period,
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
  end
end
