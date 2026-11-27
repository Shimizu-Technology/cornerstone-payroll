# frozen_string_literal: true

require "rails_helper"
require "csv"
require "roo"

RSpec.describe "Cornerstone universal workbook endpoints (staff + client portal)", type: :request do
  let(:xlsx_mime) { "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }
  let(:csv_mime) { "text/csv" }

  let(:organization) { create(:organization) }
  let(:company) do
    create(
      :company,
      organization: organization,
      name: "Fixture Universal Co",
      pay_frequency: "biweekly",
      payroll_intake_source_types: [ "cornerstone_workbook" ]
    )
  end
  let(:staff) { create(:user, organization: organization, company: company, role: "admin") }
  let(:client_user) do
    user = create(:user, organization: organization, company: company, role: "client")
    CompanyAssignment.create!(user: user, company: company)
    user
  end
  let!(:workweek) do
    CompanyWorkweek.create!(
      company: company,
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      effective_on: Date.new(2026, 1, 1),
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: staff,
      confirmed_at: Time.current,
      notes: "Confirmed workweek"
    )
  end
  let!(:pay_period) do
    create(
      :pay_period,
      company: company,
      company_workweek: workweek,
      start_date: Date.new(2026, 6, 14),
      end_date: Date.new(2026, 6, 27),
      pay_date: Date.new(2026, 7, 3),
      status: "draft"
    )
  end
  let!(:employee_01) { create(:employee, company: company, first_name: "Employee", last_name: "01", pay_rate: 20.00) }
  let!(:tax_config) do
    config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: 2026)
    create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
    config
  end

  let(:stored_objects) { {} }
  let(:storage) do
    entries = stored_objects
    Object.new.tap do |store|
      store.define_singleton_method(:upload) { |key, data, **| entries[key] = data.respond_to?(:read) ? File.binread(data.path) : data }
      store.define_singleton_method(:download_with_limit) { |key, max_bytes:| entries.fetch(key).byteslice(0, max_bytes) }
      store.define_singleton_method(:delete) { |key| entries.delete(key) }
    end
  end

  before do
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(ClientDocumentScanner).to receive(:adapter).and_return(ClientDocumentScanner::Noop.new)
  end

  describe "Staff template download and preview -> apply endpoints" do
    before { stub_portal_user(Api::V1::Admin::PayrollIntakeImportsController, staff, company) }

    it "downloads pre-filled XLSX and CSV templates and previews + applies an uploaded CSV through the merged path" do
      get "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_intake_imports/template",
          params: { source_type: "cornerstone_workbook", file_format: "xlsx" }
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq(xlsx_mime)
      expect(response.headers["Content-Disposition"]).to include("fixture-universal-co-cornerstone-workbook-2026-06-27.xlsx")

      get "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_intake_imports/template",
          params: { source_type: "cornerstone_workbook", file_format: "csv" }
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq(csv_mime)
      csv_rows = CSV.parse(response.body)
      expect(csv_rows.first).to eq(PayrollIntake::UniversalWorkbook::Template::COLUMNS)
      expect(csv_rows[1][0].to_i).to eq(employee_01.id)
      expect(csv_rows[1][1]).to eq("Employee 01")

      # Fill in Employee 01's row and upload to preview -> apply
      filled_csv = CSV.generate do |csv|
        csv << csv_rows.first
        csv << [ employee_01.id, "Employee 01", "44.00", "38.00", "", "", "4.00", "0", "50.00", "NO", "100.00", "", "", "", "25.00", "" ]
      end
      upload = portal_upload("filled.csv", filled_csv, csv_mime)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_intake_imports/preview",
           params: { source_type: "cornerstone_workbook", files: [ upload ] }
      expect(response).to have_http_status(:ok), response.body

      session_payload = response.parsed_body.fetch("import")
      row_payload = session_payload.fetch("rows").sole
      expect(row_payload).to include(
        "employee_id" => employee_01.id,
        "regular_hours" => 78.0,
        "overtime_hours" => 4.0,
        "pto_hours" => 4.0,
        "reported_tips" => 50.0,
        "tips_paid_out" => 0.0,
        "bonus" => 100.0,
        "loan_deduction" => 25.0
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_intake_imports/#{session_payload.fetch('id')}/apply",
           params: {
             rows: [ { id: row_payload.fetch("id"), disposition: "included" } ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item = pay_period.reload.payroll_items.find_by!(employee: employee_01)
      expect(item).to have_attributes(
        hours_worked: BigDecimal("78.00"),
        overtime_hours: BigDecimal("4.00"),
        pto_hours: BigDecimal("4.00"),
        reported_tips: BigDecimal("50.00"),
        tips_paid_out: BigDecimal("0.00"),
        bonus: BigDecimal("100.00"),
        bonus_source: "import",
        loan_deduction: BigDecimal("25.00"),
        import_source: "cornerstone_workbook",
        import_origin: "intake"
      )
    end
  end

  describe "Client portal template download and submission" do
    before do
      stub_portal_user(Api::V1::Client::PayrollSubmissionPeriodsController, client_user, company)
      allow(PayrollSubmissions::Catalog).to receive(:today).and_return(Date.new(2026, 6, 28))
    end

    it "downloads pre-filled XLSX and CSV templates from the client submission screen and submits a filled CSV revision" do
      ref = "#{pay_period.start_date.iso8601}_#{pay_period.end_date.iso8601}"

      get "/api/v1/client/payroll_submission_periods/#{ref}/template", params: { file_format: "xlsx" }
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq(xlsx_mime)

      get "/api/v1/client/payroll_submission_periods/#{ref}/template", params: { file_format: "csv" }
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq(csv_mime)
      csv_rows = CSV.parse(response.body)
      expect(csv_rows.first).to eq(PayrollIntake::UniversalWorkbook::Template::COLUMNS)
      expect(csv_rows[1][0].to_i).to eq(employee_01.id)

      filled_csv = CSV.generate do |csv|
        csv << csv_rows.first
        csv << [ employee_01.id, "Employee 01", "40.00", "40.00", "", "", "", "", "", "", "", "", "", "", "", "" ]
      end
      upload = portal_upload("client-filled.csv", filled_csv, csv_mime)

      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: upload,
             no_changes: "true",
             changes: "[]"
           }
      expect(response).to have_http_status(:created), response.body
      submission_docs = response.parsed_body.dig("data", "submissions", 0, "documents")
      expect(submission_docs.sole).to include("role" => "payroll_workbook", "file_name" => "client-filled.csv")
    end

    it "forbids template download when payroll files are not enabled for the client" do
      company.update!(payroll_intake_source_types: [ "spike_email" ])
      ref = "#{pay_period.start_date.iso8601}_#{pay_period.end_date.iso8601}"

      get "/api/v1/client/payroll_submission_periods/#{ref}/template", params: { file_format: "csv" }
      expect(response).to have_http_status(:forbidden)
    end

    it "supports full client portal workbook submit -> staff preview -> apply with 75 reg / 5 OT hours and $25 bonus" do
      ref = "#{pay_period.start_date.iso8601}_#{pay_period.end_date.iso8601}"
      filled_csv = CSV.generate do |csv|
        csv << PayrollIntake::UniversalWorkbook::Template::COLUMNS
        csv << [ employee_01.id, "Employee 01", "45.00", "35.00", "", "", "", "", "", "", "25.00", "", "", "", "", "" ]
      end
      upload = portal_upload("portal-biweekly.csv", filled_csv, csv_mime)

      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: upload,
             no_changes: "true",
             changes: "[]"
           }
      expect(response).to have_http_status(:created), response.body
      submission_id = response.parsed_body.dig("data", "submissions", 0, "id")
      expect(submission_id).to be_present

      # Staff previews the client-submitted universal workbook via the portal import bridge
      stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import",
           params: { submission_id: submission_id },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      preview = response.parsed_body.fetch("preview")
      expect(preview.fetch("matched_count")).to eq(1)
      expect(preview.fetch("can_apply")).to be(true)
      expect(preview.fetch("matched").sole).to include(
        "employee_id" => employee_01.id,
        "regular_hours" => 75.0,
        "overtime_hours" => 5.0,
        "bonus" => 25.0
      )

      import_id = response.parsed_body.fetch("import_id")
      portal_source_id = response.parsed_body.dig("portal_source", "selection_id")
      expect(portal_source_id).to be_present

      # Staff applies the reviewed portal workbook through PayrollIntake::ApplyService
      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: { import_id: import_id, portal_source_id: portal_source_id },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item = pay_period.reload.payroll_items.find_by!(employee: employee_01)
      expect(item.hours_worked).to eq(BigDecimal("75.00"))
      expect(item.overtime_hours).to eq(BigDecimal("5.00"))
      expect(item.hours_worked + item.overtime_hours).to eq(BigDecimal("80.00"))
      expect(item.bonus).to eq(BigDecimal("25.00"))
      expect(item.bonus_source).to eq("import")
      expect(item.import_source).to eq("cornerstone_workbook")
      # 75 * $20 + 5 * $30 + $25 bonus = $1500 + $150 + $25 = $1675.00
      expect(item.gross_pay).to eq(BigDecimal("1675.00"))
      expect(pay_period.status).to eq("calculated")

      portal_period = PayrollSubmissionPeriod.find_by!(company: company, start_date: pay_period.start_date, end_date: pay_period.end_date)
      expect(portal_period.pending_source_review?).to be(false)
      expect(portal_period.status_events.where(event: "import", payroll_submission_id: submission_id)).to exist
    end
  end

  describe "Merged apply path for reviewed-hours (mosa_revel) imports" do
    before do
      company.update!(payroll_intake_source_types: [ "mosa_revel" ])
      stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
    end

    it "routes PayrollImportsController#apply through PayrollIntake::ApplyService#apply_reviewed_import!" do
      session = PayrollIntakeSession.create!(
        company: company,
        pay_period: pay_period,
        created_by: staff,
        source_type: "mosa_revel",
        status: "previewed",
        import_hash: SecureRandom.hex(32),
        parser_version: "mosa_revel:v1",
        package_id: SecureRandom.uuid,
        package_revision: 1
      )
      PayrollIntakeRow.create!(
        payroll_intake_session: session,
        employee: employee_01,
        source_employee_name: "Employee 01",
        regular_hours: BigDecimal("80.00"),
        overtime_hours: BigDecimal("0.00"),
        reported_tips: BigDecimal("0.00"),
        tips_paid_out: BigDecimal("0.00"),
        source_payload: { "row_kind" => "matched" },
        disposition: "included",
        dispositioned_at: Time.current,
        dispositioned_by: staff
      )
      import_record = PayrollImportRecord.create!(
        pay_period: pay_period,
        payroll_intake_session: session,
        status: "previewed",
        matched_data: [
          {
            "employee_id" => employee_01.id,
            "employee_name" => "Employee 01",
            "match_status" => "matched",
            "regular_hours" => 80.0,
            "overtime_hours" => 0.0,
            "tips" => 0.0,
            "loan_deduction" => 0.0
          }
        ],
        raw_data: {
          "tips_paid_out_from_tips" => false,
          "low_confidence_matches" => []
        }
      )

      verifier = instance_double(PayrollIntake::SourcePackageVerifier, verify!: true)
      allow(PayrollIntake::SourcePackageVerifier).to receive(:new).with(session: session).and_return(verifier)
      completeness = instance_double(
        PayrollIntake::SourceCompleteness,
        waivable_missing_roles: [],
        missing_required_roles: []
      )
      allow(PayrollIntake::SourceCompleteness).to receive(:new).and_return(completeness)
      expect_any_instance_of(PayrollIntake::ApplyService).to receive(:apply_reviewed_import!).and_call_original

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: { import_id: import_record.id },
           as: :json

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("results", "success").length).to eq(1)
      item = pay_period.reload.payroll_items.find_by!(employee: employee_01)
      expect(item.hours_worked).to eq(BigDecimal("80.00"))
      expect(session.reload.status).to eq("applied")
    end
  end
end
