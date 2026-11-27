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
        "bonus" => 25.0,
        "confidence" => 1.0,
        "pay_rate" => 20.0
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

    it "applies staff-approved client extra_hours (6.50h in week 2 @ $20/hr) on top of a portal universal workbook (75 reg / 5 OT + $25 bonus -> 80 reg / 6.5 OT = $1,820 gross)" do
      ref = "#{pay_period.start_date.iso8601}_#{pay_period.end_date.iso8601}"
      primary_rate = employee_01.employee_wage_rates.find_by(is_primary: true) ||
        employee_01.employee_wage_rates.create!(label: "Primary", rate: 20.00, is_primary: true, active: true)

      filled_csv = CSV.generate do |csv|
        csv << PayrollIntake::UniversalWorkbook::Template::COLUMNS
        csv << [ employee_01.id, "Employee 01", "45.00", "35.00", "", "", "", "", "", "", "25.00", "", "", "", "", "" ]
      end
      upload = portal_upload("portal-with-extra-hours.csv", filled_csv, csv_mime)

      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: upload,
             no_changes: "false",
             changes: [
               {
                 kind: "extra_hours",
                 employee_id: employee_01.id,
                 employee_wage_rate_id: primary_rate.id,
                 hours: "6.50",
                 workweek: 2
               }
             ].to_json
           }
      expect(response).to have_http_status(:created), response.body
      submission_id = response.parsed_body.dig("data", "submissions", 0, "id")

      stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import",
           params: { submission_id: submission_id },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      prefill_rows = response.parsed_body.dig("client_change_prefill", "rows")
      expect(prefill_rows.sole).to include(
        "change_index" => 0,
        "kind" => "extra_hours",
        "employee_id" => employee_01.id,
        "hours" => "6.5",
        "workweek" => 2,
        "resulting_regular_hours" => "80.0",
        "resulting_overtime_hours" => "6.5",
        "gross_pay_delta" => "145.00"
      )

      import_id = response.parsed_body.fetch("import_id")
      portal_source_id = response.parsed_body.dig("portal_source", "selection_id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: import_id,
             portal_source_id: portal_source_id,
             confirm_client_changes: true,
             reviewed_changes: [
               { change_index: 0, hours: "6.50", workweek: 2, preview_token: prefill_rows.sole.fetch("preview_token"), decision: "apply" }
             ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item = pay_period.reload.payroll_items.find_by!(employee: employee_01)
      # Workbook: Week 1 = 45, Week 2 = 35 -> 75.00 reg + 5.00 OT + $25 bonus = $1,675.00
      # Approved client change: +6.50 extra hours in week 2 -> Week 2 = 41.50 (+5.00 reg @ $20 + 1.50 OT @ $30 = +$145.00) -> $1,820.00 gross
      expect(item.hours_worked).to eq(BigDecimal("80.00"))
      expect(item.overtime_hours).to eq(BigDecimal("6.50"))
      expect(item.bonus).to eq(BigDecimal("25.00"))
      expect(item.gross_pay).to eq(BigDecimal("1820.00"))
      expect(item.custom_columns_data.dig("client_change_evidence", "applied_regular_hours")).to eq("80.0")
      expect(item.custom_columns_data.dig("client_change_evidence", "applied_overtime_hours")).to eq("6.5")
    end

    it "clears withdrawn extra_hours client_change_evidence across rev 1 -> rev 2 -> rev 3 so omitting the employee in rev 3 succeeds" do
      employee_02 = create(:employee, company: company, first_name: "Employee", last_name: "02", pay_rate: 25.00)
      primary_rate = employee_01.employee_wage_rates.find_by(is_primary: true) ||
        employee_01.employee_wage_rates.create!(label: "Primary", rate: 20.00, is_primary: true, active: true)
      ref = "#{pay_period.start_date.iso8601}_#{pay_period.end_date.iso8601}"

      # Rev 1: workbook 45+35 (75 reg / 5 OT) + $25 bonus + 3.25 approved extra hours in week 2 @ $20 -> 78.25 reg / 5 OT, $1,740 gross
      rev1_csv = CSV.generate do |csv|
        csv << PayrollIntake::UniversalWorkbook::Template::COLUMNS
        csv << [ employee_01.id, "Employee 01", "45.00", "35.00", "", "", "", "", "", "", "25.00", "", "", "", "", "" ]
      end
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: portal_upload("rev1.csv", rev1_csv, csv_mime),
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: employee_01.id, employee_wage_rate_id: primary_rate.id, hours: "3.25", workweek: 2 }
             ].to_json
           }
      expect(response).to have_http_status(:created), response.body
      rev1_id = response.parsed_body.dig("data", "submissions", 0, "id")

      stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: rev1_id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      rev1_package_id = response.parsed_body.dig("source_package", "package_id")
      rev1_token = response.parsed_body.dig("client_change_prefill", "rows", 0, "preview_token")
      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id"),
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, hours: "3.25", workweek: 2, preview_token: rev1_token, decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item1 = pay_period.reload.payroll_items.find_by!(employee: employee_01)
      expect(item1.hours_worked).to eq(BigDecimal("78.25"))
      expect(item1.gross_pay).to eq(BigDecimal("1740.00"))
      expect(item1.custom_columns_data.dig("client_change_evidence", "applied_regular_hours")).to eq("78.25")

      # Rev 2: withdraws extra hours and adds $1 bonus ($26 total) -> 75 reg, $1,676 gross, clears client_change_evidence
      rev2_csv = CSV.generate do |csv|
        csv << PayrollIntake::UniversalWorkbook::Template::COLUMNS
        csv << [ employee_01.id, "Employee 01", "45.00", "35.00", "", "", "", "", "", "", "26.00", "", "", "", "", "" ]
      end
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: portal_upload("rev2.csv", rev2_csv, csv_mime),
             based_on_revision: 1,
             no_changes: "true",
             changes: "[]"
           }
      expect(response).to have_http_status(:created), response.body
      rev2_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import",
           params: {
             submission_id: rev2_id,
             supersedes_package_id: rev1_package_id,
             supersession_reason: "Client withdrew extra hours and adjusted bonus"
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body
      rev2_package_id = response.parsed_body.dig("source_package", "package_id")
      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id")
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item1.reload
      expect(item1.hours_worked).to eq(BigDecimal("75.00"))
      expect(item1.bonus).to eq(BigDecimal("26.00"))
      expect(item1.gross_pay).to eq(BigDecimal("1676.00"))
      expect(item1.custom_columns_data["client_change_evidence"]).to be_nil

      # Rev 3: omits Employee 01 and includes Employee 02 -> applies 200 without false 422, saves Employee 02
      rev3_csv = CSV.generate do |csv|
        csv << PayrollIntake::UniversalWorkbook::Template::COLUMNS
        csv << [ employee_02.id, "Employee 02", "40.00", "40.00", "", "", "", "", "", "", "", "", "", "", "", "" ]
      end
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: portal_upload("rev3.csv", rev3_csv, csv_mime),
             based_on_revision: 2,
             no_changes: "true",
             changes: "[]"
           }
      expect(response).to have_http_status(:created), response.body
      rev3_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import",
           params: {
             submission_id: rev3_id,
             supersedes_package_id: rev2_package_id,
             supersession_reason: "Client updated workbook roster"
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body
      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id")
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item1.reload
      expect(item1.hours_worked).to eq(BigDecimal("75.00"))
      expect(item1.gross_pay).to eq(BigDecimal("1676.00"))
      expect(item1.custom_columns_data["client_change_evidence"]).to be_nil

      item2 = pay_period.reload.payroll_items.find_by!(employee: employee_02)
      expect(item2.hours_worked).to eq(BigDecimal("80.00"))
      expect(item2.gross_pay).to eq(BigDecimal("2000.00"))
    end
  end

  describe "Concurrent open reviews across mosa_revel and direct cornerstone_workbook" do
    before do
      company.update!(payroll_intake_source_types: [ "mosa_revel", "cornerstone_workbook" ])
    end

    it "keeps an open MoSa review (73 reg / 2 OT) reachable via current_import after a direct universal workbook preview at revision 2" do
      mosa_session = PayrollIntakeSession.create!(
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
        payroll_intake_session: mosa_session,
        employee: employee_01,
        source_employee_name: "Employee 01",
        regular_hours: BigDecimal("73.00"),
        overtime_hours: BigDecimal("2.00"),
        reported_tips: BigDecimal("0.00"),
        tips_paid_out: BigDecimal("0.00"),
        source_payload: {
          "row_kind" => "matched",
          "preview_row" => {
            "employee_id" => employee_01.id,
            "employee_name" => "Employee 01",
            "match_status" => "matched",
            "regular_hours" => 73.0,
            "overtime_hours" => 2.0,
            "tips" => 0.0,
            "loan_deduction" => 0.0
          }
        },
        disposition: "pending"
      )
      mosa_import_record = PayrollImportRecord.create!(
        pay_period: pay_period,
        payroll_intake_session: mosa_session,
        status: "previewed",
        matched_data: [
          {
            "employee_id" => employee_01.id,
            "employee_name" => "Employee 01",
            "match_status" => "matched",
            "regular_hours" => 73.0,
            "overtime_hours" => 2.0,
            "tips" => 0.0,
            "loan_deduction" => 0.0
          }
        ],
        raw_data: { "tips_paid_out_from_tips" => false, "low_confidence_matches" => [] }
      )

      # Preview a direct universal workbook -> creates revision 2 session without a PayrollImportRecord
      stub_portal_user(Api::V1::Admin::PayrollIntakeImportsController, staff, company)
      workbook_csv = CSV.generate do |csv|
        csv << PayrollIntake::UniversalWorkbook::Template::COLUMNS
        csv << [ employee_01.id, "Employee 01", "40.00", "40.00", "", "", "", "", "", "", "", "", "", "", "", "" ]
      end
      post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_intake_imports/preview",
           params: { source_type: "cornerstone_workbook", files: [ portal_upload("direct.csv", workbook_csv, csv_mime) ] }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("import", "package_revision")).to eq(2)

      # Reopening current_import must still return the open MoSa revision 1 review (not 404)
      stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
      get "/api/v1/admin/pay_periods/#{pay_period.id}/current_import"
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.fetch("import_id")).to eq(mosa_import_record.id)
      expect(response.parsed_body.dig("source_package", "package_revision")).to eq(1)
      expect(response.parsed_body.dig("preview", "matched").sole).to include(
        "employee_id" => employee_01.id,
        "regular_hours" => 73.0,
        "overtime_hours" => 2.0
      )
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

    it "rolls back all rows on mid-apply failure, keeps the session previewed, and succeeds on retry" do
      employee_02 = create(:employee, company: company, first_name: "Employee", last_name: "02", pay_rate: 22.00)
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
      [ employee_01, employee_02 ].each_with_index do |emp, idx|
        PayrollIntakeRow.create!(
          payroll_intake_session: session,
          employee: emp,
          position: idx,
          source_employee_name: emp.full_name,
          regular_hours: BigDecimal("80.00"),
          overtime_hours: BigDecimal("0.00"),
          reported_tips: BigDecimal("0.00"),
          tips_paid_out: BigDecimal("0.00"),
          source_payload: { "row_kind" => "matched" },
          disposition: "included",
          dispositioned_at: Time.current,
          dispositioned_by: staff
        )
      end
      import_record = PayrollImportRecord.create!(
        pay_period: pay_period,
        payroll_intake_session: session,
        status: "previewed",
        matched_data: [ employee_01, employee_02 ].map do |emp|
          {
            "employee_id" => emp.id,
            "employee_name" => emp.full_name,
            "match_status" => "matched",
            "regular_hours" => 80.0,
            "overtime_hours" => 0.0,
            "tips" => 0.0,
            "loan_deduction" => 0.0
          }
        end,
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

      # Force the second employee's calculation to fail after the first saves
      fail_second = true
      allow_any_instance_of(PayrollItem).to receive(:calculate!).and_wrap_original do |original, *args|
        if fail_second && original.receiver.employee_id == employee_02.id
          raise ArgumentError, "Simulated calculation failure for second employee"
        end

        original.call(*args)
      end

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: { import_id: import_record.id },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(pay_period.reload.payroll_items).to be_empty
      expect(session.reload.status).to eq("previewed")
      expect(import_record.reload.status).to eq("previewed")

      # Clear the failure and retry the exact same review
      fail_second = false
      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: { import_id: import_record.id },
           as: :json

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("results", "success").length).to eq(2)
      expect(pay_period.reload.payroll_items.pluck(:employee_id)).to contain_exactly(employee_01.id, employee_02.id)
      expect(session.reload.status).to eq("applied")
      expect(import_record.reload.status).to eq("applied")
    end

    it "rolls back portal selection.applied_at and client decisions on workbook row error, then succeeds on retry" do
      allow(PayrollSubmissions::Catalog).to receive(:today).and_return(Date.new(2026, 6, 28))
      company.update!(payroll_intake_source_types: [ "cornerstone_workbook" ])
      employee_02 = create(:employee, company: company, first_name: "Employee", last_name: "02", pay_rate: 22.00)
      owner = create(
        :employee,
        company: company,
        first_name: "Owner",
        last_name: "03",
        employment_type: "salary",
        salary_type: "variable",
        pay_rate: 0
      )
      create(
        :payroll_item,
        pay_period: pay_period,
        employee: owner,
        employment_type: "salary",
        salary_override: BigDecimal("1500.00"),
        import_source: "mosa_revel",
        custom_columns_data: {
          "client_change_evidence" => { "kind" => "owner_pay", "submission_id" => 999_999, "reviewed_value" => "1500.00" },
          "period_pay_evidence" => { "source_type" => "client_submission" }
        }
      )
      # Existing manual row for employee_02 causes a row error when force_overwrite is false
      create(
        :payroll_item,
        pay_period: pay_period,
        employee: employee_02,
        employment_type: "hourly",
        pay_rate: BigDecimal("22.00"),
        hours_worked: BigDecimal("10.00"),
        import_source: nil
      )

      workbook_csv = CSV.generate do |csv|
        csv << PayrollIntake::UniversalWorkbook::Template::COLUMNS
        csv << [ employee_01.id, "Employee 01", "45.00", "35.00", "", "", "", "", "0.00", "NO", "25.00", "", "", "", "", "" ]
        csv << [ employee_02.id, "Employee 02", "40.00", "40.00", "", "", "", "", "0.00", "NO", "", "", "", "", "", "" ]
      end
      ref = "#{pay_period.start_date.iso8601}_#{pay_period.end_date.iso8601}"
      stub_portal_user(Api::V1::Client::PayrollSubmissionPeriodsController, client_user, company)
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: portal_upload("portal-rollback.csv", workbook_csv, csv_mime),
             no_changes: "true",
             changes: "[]"
           }
      expect(response).to have_http_status(:created), response.body
      submission_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import",
           params: { submission_id: submission_id },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      preview_body = response.parsed_body
      import_id = preview_body.fetch("import_id")
      selection_id = preview_body.dig("portal_source", "selection_id")
      owner_change = preview_body.dig("client_change_prefill", "rows").find { |row| row["employee_id"] == owner.id }
      expect(owner_change).to be_present

      selection = PayrollSubmissionImport.find(selection_id)
      import_record = PayrollImportRecord.find(import_id)
      session = import_record.payroll_intake_session

      # Verify decimal persistence in matched_data
      emp1_matched = import_record.matched_data.find { |row| row["employee_id"] == employee_01.id }
      expect(emp1_matched["bonus"]).to eq("25.0")
      expect(emp1_matched["tips"]).to eq("0.0")

      # Apply without force_overwrite: employee_02 triggers a row error after employee_01,
      # selection.applied_at, and the owner no_pay exclusion were written in the transaction.
      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: import_id,
             portal_source_id: selection_id,
             confirm_client_changes: true,
             reviewed_changes: [
               {
                 change_index: owner_change.fetch("change_index"),
                 decision: "no_pay",
                 reason: "Owner skipping draw this period"
               }
             ]
           },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity), response.body
      expect(response.parsed_body.dig("details", "row_errors").map { |err| err["employee_id"] }).to include(employee_02.id)
      expect(selection.reload.applied_at).to be_nil
      expect(pay_period.pay_period_excluded_employees.where(employee_id: owner.id)).to be_empty
      expect(pay_period.payroll_items.exists?(employee_id: owner.id)).to be(true)
      expect(pay_period.payroll_items.exists?(employee_id: employee_01.id)).to be(false)
      expect(session.reload.status).to eq("previewed")
      expect(import_record.reload.status).to eq("previewed")

      # Retry the exact same review with force_overwrite: true and confirm it applies cleanly
      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: import_id,
             portal_source_id: selection_id,
             force_overwrite: true,
             confirm_client_changes: true,
             reviewed_changes: [
               {
                 change_index: owner_change.fetch("change_index"),
                 decision: "no_pay",
                 reason: "Owner skipping draw this period"
               }
             ]
           },
           as: :json

      expect(response).to have_http_status(:ok), response.body
      expect(selection.reload.applied_at).to be_present
      expect(pay_period.pay_period_excluded_employees.where(employee_id: owner.id)).to exist
      expect(pay_period.payroll_items.exists?(employee_id: owner.id)).to be(false)
      expect(pay_period.payroll_items.find_by!(employee_id: employee_01.id).hours_worked).to eq(BigDecimal("75.00"))
      expect(pay_period.payroll_items.find_by!(employee_id: employee_02.id).hours_worked).to eq(BigDecimal("80.00"))
      expect(session.reload.status).to eq("applied")
      expect(import_record.reload.status).to eq("applied")

      # Audit metadata reports retained verified source role ("cornerstone_workbook") rather than "supplemental_workbook"
      controller_probe = Api::V1::Admin::PayrollImportsController.new
      controller_probe.instance_variable_set(:@audit_import_record, import_record)
      expect(controller_probe.send(:audit_record_metadata, nil)[:source_files]).to eq([ "cornerstone_workbook" ])
    end

    it "scopes tip_treatment and rematch to source_type when a MoSa review and a newer portal workbook review are both current" do
      allow(PayrollSubmissions::Catalog).to receive(:today).and_return(Date.new(2026, 6, 28))
      mosa_session = PayrollIntakeSession.create!(
        company: company,
        pay_period: pay_period,
        created_by: staff,
        source_type: "mosa_revel",
        status: "draft",
        import_hash: SecureRandom.hex(32),
        parser_version: "mosa_revel:v1",
        package_id: SecureRandom.uuid,
        package_revision: 1,
        warnings: [ { "code" => "legacy_mosa_workbook", "severity" => "warning", "message" => "Legacy MoSa workbook" } ],
        evidence_snapshot: { "preview" => { "pdf_count" => 0, "excel_count" => 1 } }
      )
      mosa_session.documents.create!(
        document_type: "other",
        source_role: "supplemental_workbook",
        filename: "legacy-tips.xlsx",
        content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        storage_reference: "test/mosa-legacy-tips-#{SecureRandom.hex(6)}.xlsx",
        byte_size: 12,
        sha256: Digest::SHA256.hexdigest("legacy-tips"),
        verification_status: "verified",
        verified_at: Time.current,
        position: 0,
        metadata: { "legacy_tip_format" => true }
      )
      mosa_session.update!(status: "previewed")
      mosa_record = PayrollImportRecord.create!(
        pay_period: pay_period,
        payroll_intake_session: mosa_session,
        status: "previewed",
        excel_filename: "legacy-tips.xlsx",
        matched_data: [],
        raw_data: { "tips_paid_out_from_tips" => false }
      )

      company.update!(payroll_intake_source_types: [ "cornerstone_workbook" ])
      workbook_csv = CSV.generate do |csv|
        csv << PayrollIntake::UniversalWorkbook::Template::COLUMNS
        csv << [ employee_01.id, "Employee 01", "40.00", "40.00", "", "", "", "", "15.00", "NO", "", "", "", "", "", "" ]
      end
      ref = "#{pay_period.start_date.iso8601}_#{pay_period.end_date.iso8601}"
      stub_portal_user(Api::V1::Client::PayrollSubmissionPeriodsController, client_user, company)
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: portal_upload("newer-portal.csv", workbook_csv, csv_mime),
             no_changes: "true",
             changes: "[]"
           }
      expect(response).to have_http_status(:created), response.body
      submission_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import",
           params: { submission_id: submission_id },
           as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("source_package", "source_type")).to eq("cornerstone_workbook")
      portal_import_id = response.parsed_body.fetch("import_id")
      portal_record = PayrollImportRecord.find(portal_import_id)
      portal_session = portal_record.payroll_intake_session
      company.update!(payroll_intake_source_types: [ "mosa_revel", "cornerstone_workbook" ])

      # Update tip_treatment on the MoSa review explicitly via source_type while the newer portal review is current
      post "/api/v1/admin/pay_periods/#{pay_period.id}/import_tip_treatment",
           params: {
             import_id: mosa_record.id,
             tips_paid_out_from_tips: true,
             source_type: "mosa_revel"
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("source_package", "source_type")).to eq("mosa_revel")
      expect(mosa_record.reload.raw_data["tips_paid_out_from_tips"]).to be(true)
      expect(portal_record.reload.raw_data["tips_paid_out_from_tips"]).not_to be(true)

      # Rematch the MoSa review explicitly via source_type without touching the portal review
      rematched_result = { session: mosa_session, duplicate: true }
      preview_double = instance_double(PayrollIntake::PreviewService, call: rematched_result)
      expect(PayrollIntake::PreviewService).to receive(:new).with(
        hash_including(pay_period: pay_period, source_type: "mosa_revel", carry_forward: true)
      ).and_return(preview_double)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/rematch_import",
           params: { source_type: "mosa_revel" },
           as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("source_package", "source_type")).to eq("mosa_revel")
      expect(portal_session.reload.status).to eq("previewed")
      expect(portal_record.reload.status).to eq("previewed")
    end
  end
end
