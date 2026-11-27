# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Extra hours overtime handling (issue #665)", type: :request do
  let(:csv_mime) { "text/csv" }
  let(:pdf_mime) { "application/pdf" }
  let(:organization) { create(:organization) }
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

  def setup_tax_config(year = 2026)
    config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: year)
    create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
    config
  end

  describe "biweekly universal workbook (7-day workweek overtime)" do
    let(:company) do
      create(
        :company,
        organization: organization,
        name: "Synthetic Biweekly Co",
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
        notes: "Confirmed Sunday workweek"
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
    let!(:employee) { create(:employee, company: company, first_name: "Worker", last_name: "Alpha", pay_rate: 20.00) }
    let!(:primary_rate) do
      employee.employee_wage_rates.find_by(is_primary: true) ||
        employee.employee_wage_rates.create!(label: "Primary", rate: 20.00, is_primary: true, active: true)
    end
    let(:ref) { "#{pay_period.start_date.iso8601}_#{pay_period.end_date.iso8601}" }

    before do
      setup_tax_config(2026)
      allow(PayrollSubmissions::Catalog).to receive(:today).and_return(Date.new(2026, 6, 28))
      stub_portal_user(Api::V1::Client::PayrollSubmissionPeriodsController, client_user, company)
      stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
    end

    def workbook_upload(week1:, week2:, target: employee, bonus: "")
      csv_body = CSV.generate do |csv|
        csv << PayrollIntake::UniversalWorkbook::Template::COLUMNS
        csv << [ target.id, target.full_name, week1, week2, "", "", "", "", "", "", bonus, "", "", "", "", "" ]
      end
      portal_upload("biweekly.csv", csv_body, csv_mime)
    end

    it "exposes both workweek date ranges in the portal period detail" do
      get "/api/v1/client/payroll_submission_periods/#{ref}"
      expect(response).to have_http_status(:ok), response.body
      config = response.parsed_body.dig("data", "extra_hours_config")
      expect(config).to eq(
        "mode" => "workweek",
        "overtime_mode" => "weekly_split",
        "workweeks" => [
          { "index" => 1, "start_date" => "2026-06-14", "end_date" => "2026-06-20", "label" => "Jun 14–20" },
          { "index" => 2, "start_date" => "2026-06-21", "end_date" => "2026-06-27", "label" => "Jun 21–27" }
        ]
      )
    end

    it "recomputes week 2 overtime: 45/35 + 6.50 in week 2 -> 80.00 reg / 6.50 OT / $1,795.00 gross (+$145.00)" do
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: workbook_upload(week1: "45.00", week2: "35.00"),
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: employee.id, employee_wage_rate_id: primary_rate.id, hours: "6.50", workweek: 2 }
             ].to_json
           }
      expect(response).to have_http_status(:created), response.body
      submission_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: submission_id }, as: :json
      expect(response).to have_http_status(:ok), response.body

      prefill = response.parsed_body.dig("client_change_prefill", "rows").sole
      expect(prefill).to include(
        "extra_hours_mode" => "workweek",
        "workweek" => 2,
        "workweek_start_date" => "2026-06-21",
        "workweek_end_date" => "2026-06-27",
        "needs_classification" => false,
        "baseline_regular_hours" => "75.0",
        "baseline_overtime_hours" => "5.0",
        "baseline_week1_hours" => "45.0",
        "baseline_week2_hours" => "35.0",
        "delta_regular_hours" => "5.0",
        "delta_overtime_hours" => "1.5",
        "resulting_regular_hours" => "80.0",
        "resulting_overtime_hours" => "6.5",
        "gross_pay_delta" => "145.00"
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id"),
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, hours: "6.50", workweek: 2, decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item = pay_period.reload.payroll_items.find_by!(employee: employee)
      # Week 1 = 45 (40 reg / 5 OT), Week 2 = 35 + 6.50 = 41.50 (40 reg / 1.50 OT)
      # Total: 80.00 reg @ $20 ($1,600.00) + 6.50 OT @ $30 ($195.00) = $1,795.00
      expect(item.hours_worked).to eq(BigDecimal("80.00"))
      expect(item.overtime_hours).to eq(BigDecimal("6.50"))
      expect(item.gross_pay).to eq(BigDecimal("1795.00"))
      expect(item.wage_rate_hours.sole).to include("regular_hours" => 80.0, "overtime_hours" => 6.5)
      expect(item.custom_columns_data["client_change_evidence"]).to include(
        "hours_mode" => "workweek",
        "workweek" => 2,
        "workweek_start_date" => "2026-06-21",
        "workweek_end_date" => "2026-06-27",
        "delta_regular_hours" => "5.0",
        "delta_overtime_hours" => "1.5",
        "gross_pay_delta" => "145.00",
        "applied_regular_hours" => "80.0",
        "applied_overtime_hours" => "6.5"
      )
    end

    it "recomputes week 1 overtime: 45/35 + 6.50 in week 1 -> 75.00 reg / 11.50 OT / $1,845.00 gross (+$195.00)" do
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: workbook_upload(week1: "45.00", week2: "35.00"),
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: employee.id, employee_wage_rate_id: primary_rate.id, hours: "6.50", workweek: 1 }
             ].to_json
           }
      expect(response).to have_http_status(:created), response.body
      submission_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: submission_id }, as: :json
      expect(response).to have_http_status(:ok), response.body

      prefill = response.parsed_body.dig("client_change_prefill", "rows").sole
      expect(prefill).to include(
        "workweek" => 1,
        "delta_regular_hours" => "0.0",
        "delta_overtime_hours" => "6.5",
        "resulting_regular_hours" => "75.0",
        "resulting_overtime_hours" => "11.5",
        "gross_pay_delta" => "195.00"
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id"),
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, hours: "6.50", workweek: 1, decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item = pay_period.reload.payroll_items.find_by!(employee: employee)
      # Week 1 = 45 + 6.50 = 51.50 (40 reg / 11.50 OT), Week 2 = 35 (35 reg / 0 OT)
      # Total: 75.00 reg @ $20 ($1,500.00) + 11.50 OT @ $30 ($345.00) = $1,845.00
      expect(item.hours_worked).to eq(BigDecimal("75.00"))
      expect(item.overtime_hours).to eq(BigDecimal("11.50"))
      expect(item.gross_pay).to eq(BigDecimal("1845.00"))
    end

    it "rejects a new biweekly client submission without a workweek" do
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: workbook_upload(week1: "45.00", week2: "35.00"),
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: employee.id, employee_wage_rate_id: primary_rate.id, hours: "6.50" }
             ].to_json
           }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "changes.1").join).to include("workweek")
    end

    it "requires staff to choose a workweek for an existing pending change that has none (never silently assumes regular)" do
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: workbook_upload(week1: "45.00", week2: "35.00"),
             no_changes: "true",
             changes: "[]"
           }
      expect(response).to have_http_status(:created), response.body
      submission = PayrollSubmission.find(response.parsed_body.dig("data", "submissions", 0, "id"))
      # Simulate a pre-existing pending change saved before workweek was captured
      submission.update_columns(
        no_changes: false,
        change_rows: [
          {
            "kind" => "extra_hours",
            "employee_id" => employee.id,
            "employee_wage_rate_id" => primary_rate.id,
            "wage_rate" => "20.0",
            "wage_rate_label" => "Primary",
            "hours" => "6.5"
          }
        ]
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: submission.id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      prefill = response.parsed_body.dig("client_change_prefill", "rows").sole
      expect(prefill).to include("extra_hours_mode" => "workweek", "needs_classification" => true)
      expect(prefill["workweek"]).to be_nil

      import_id = response.parsed_body.fetch("import_id")
      selection_id = response.parsed_body.dig("portal_source", "selection_id")

      # Applying without choosing a workweek is rejected
      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: import_id,
             portal_source_id: selection_id,
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, hours: "6.5", decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("workweek")
      expect(pay_period.payroll_items).to be_empty

      # Applying after staff selects Week 2 succeeds with exact OT recomputation
      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: import_id,
             portal_source_id: selection_id,
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, hours: "6.5", workweek: 2, decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body
      item = pay_period.reload.payroll_items.find_by!(employee: employee)
      expect(item.hours_worked).to eq(BigDecimal("80.00"))
      expect(item.overtime_hours).to eq(BigDecimal("6.50"))
      expect(item.gross_pay).to eq(BigDecimal("1795.00"))
    end

    it "falls back to regular/overtime split when an employee has saved worksheet hours with no per-week breakdown" do
      other = create(:employee, company: company, first_name: "Manual", last_name: "Worker", pay_rate: 20.00)
      other_rate = other.employee_wage_rates.find_by(is_primary: true) ||
        other.employee_wage_rates.create!(label: "Primary", rate: 20.00, is_primary: true, active: true)
      create(:payroll_item, company: company, pay_period: pay_period, employee: other,
             employment_type: "hourly", pay_rate: 20.00, hours_worked: 30.00, overtime_hours: 0.00,
             import_source: nil)

      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: workbook_upload(week1: "40.00", week2: "40.00"),
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: other.id, employee_wage_rate_id: other_rate.id, hours: "6.50", workweek: 2 }
             ].to_json
           }
      expect(response).to have_http_status(:created), response.body
      submission_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: submission_id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      prefill = response.parsed_body.dig("client_change_prefill", "rows").sole
      expect(prefill).to include(
        "extra_hours_mode" => "split",
        "needs_classification" => true,
        "fallback_reason" => include("no weekly breakdown")
      )

      import_id = response.parsed_body.fetch("import_id")
      selection_id = response.parsed_body.dig("portal_source", "selection_id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: import_id,
             portal_source_id: selection_id,
             force_overwrite: true,
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, regular_hours: "4", overtime_hours: "2.5", decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item = pay_period.reload.payroll_items.find_by!(employee: other)
      expect(item.hours_worked).to eq(BigDecimal("34.00"))
      expect(item.overtime_hours).to eq(BigDecimal("2.50"))
      # 34 * $20 ($680) + 2.5 * $30 ($75) = $755.00
      expect(item.gross_pay).to eq(BigDecimal("755.00"))
    end

    it "keeps 1099 hourly contractor extra hours straight time with no overtime premium" do
      contractor = create(
        :employee,
        company: company,
        first_name: "Contractor",
        last_name: "Hourly",
        employment_type: "contractor",
        contractor_pay_type: "hourly",
        pay_rate: 20.00
      )
      contractor_rate = contractor.employee_wage_rates.find_by(is_primary: true) ||
        contractor.employee_wage_rates.create!(label: "Contract Hourly", rate: 20.00, is_primary: true, active: true)

      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: workbook_upload(week1: "40.00", week2: "35.00", target: contractor),
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: contractor.id, employee_wage_rate_id: contractor_rate.id, hours: "6.50" }
             ].to_json
           }
      expect(response).to have_http_status(:created), response.body
      submission_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: submission_id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      prefill = response.parsed_body.dig("client_change_prefill", "rows").sole
      expect(prefill).to include(
        "extra_hours_mode" => "straight_time",
        "is_contractor" => true,
        "delta_regular_hours" => "6.5",
        "delta_overtime_hours" => "0.0",
        "gross_pay_delta" => "130.00"
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id"),
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, hours: "6.50", decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item = pay_period.reload.payroll_items.find_by!(employee: contractor)
      # 75 + 6.50 = 81.50 straight time @ $20/hr = $1,630.00, 0 OT
      expect(item.hours_worked).to eq(BigDecimal("81.50"))
      expect(item.overtime_hours).to eq(BigDecimal("0.00"))
      expect(item.gross_pay).to eq(BigDecimal("1630.00"))
    end

    it "resolves portal picker compensation as of period end date for W-2 -> 1099 and 1099 -> W-2 transitions" do
      # Employee A: W-2 hourly in June, transitions to 1099 hourly on July 1
      w2_to_1099 = create(:employee, company: company, first_name: "JuneW2", last_name: "JulyContractor",
                          employment_type: "hourly", pay_rate: 20.00)
      w2_to_1099_rate = w2_to_1099.employee_wage_rates.find_by(is_primary: true) ||
        w2_to_1099.employee_wage_rates.create!(label: "Primary", rate: 20.00, is_primary: true, active: true)

      # Employee B: 1099 hourly in June, transitions to W-2 hourly on July 1
      contractor_to_w2 = create(:employee, company: company, first_name: "JuneContractor", last_name: "JulyW2",
                                employment_type: "contractor", contractor_pay_type: "hourly", pay_rate: 20.00)
      contractor_to_w2_rate = contractor_to_w2.employee_wage_rates.find_by(is_primary: true) ||
        contractor_to_w2.employee_wage_rates.create!(label: "Primary", rate: 20.00, is_primary: true, active: true)

      allow(PayrollBusinessClock).to receive(:today).and_return(Date.new(2026, 7, 2))
      allow(PayrollSubmissions::Catalog).to receive(:today).and_return(Date.new(2026, 7, 2))

      w2_to_1099.allow_tax_classification_change = true
      EmployeeCompensationChangeService.new(
        employee: w2_to_1099,
        actor: staff,
        source: "spec",
        effective_on: Date.new(2026, 7, 1),
        basis: { employment_type: "contractor", contractor_pay_type: "hourly" }
      ).call!
      contractor_to_w2.allow_tax_classification_change = true
      EmployeeCompensationChangeService.new(
        employee: contractor_to_w2,
        actor: staff,
        source: "spec",
        effective_on: Date.new(2026, 7, 1),
        basis: { employment_type: "hourly", contractor_pay_type: nil }
      ).call!

      stub_portal_user(Api::V1::Client::EmployeesController, client_user, company)

      # Without rates_on, picker reflects July 2 (today)
      get "/api/v1/client/employees", params: { status: "active", per_page: 200 }
      expect(response).to have_http_status(:ok), response.body
      today_by_id = response.parsed_body.fetch("data").index_by { |row| row["id"] }
      expect(today_by_id.fetch(w2_to_1099.id)["employment_type"]).to eq("contractor")
      expect(today_by_id.fetch(contractor_to_w2.id)["employment_type"]).to eq("hourly")

      # With rates_on=2026-06-27 (period end date), picker matches server validation for June 14-27
      get "/api/v1/client/employees", params: { status: "active", per_page: 200, rates_on: "2026-06-27" }
      expect(response).to have_http_status(:ok), response.body
      june_by_id = response.parsed_body.fetch("data").index_by { |row| row["id"] }
      expect(june_by_id.fetch(w2_to_1099.id)["employment_type"]).to eq("hourly")
      expect(june_by_id.fetch(contractor_to_w2.id)).to include("employment_type" => "contractor", "contractor_pay_type" => "hourly")

      # Malformed and out-of-range rates_on values are refused (422)
      get "/api/v1/client/employees", params: { status: "active", rates_on: "not-a-date" }
      expect(response).to have_http_status(:unprocessable_entity)

      get "/api/v1/client/employees", params: { status: "active", rates_on: "9999-12-31" }
      expect(response).to have_http_status(:unprocessable_entity)

      # Valid ISO date that is NOT an open submittable period end date is refused (422)
      get "/api/v1/client/employees", params: { status: "active", rates_on: "2026-06-26" }
      expect(response).to have_http_status(:unprocessable_entity)

      # Client viewer is refused rates_on (403) while omitted param keeps today's behavior unchanged
      viewer = create(:user, organization: organization, company: company, role: "client", client_access_level: "viewer")
      CompanyAssignment.create!(user: viewer, company: company)
      stub_portal_user(Api::V1::Client::EmployeesController, viewer, company)

      get "/api/v1/client/employees", params: { status: "active", rates_on: "2026-06-27" }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("client_view_only")

      get "/api/v1/client/employees", params: { status: "active", per_page: 200 }
      expect(response).to have_http_status(:ok), response.body
      viewer_today_by_id = response.parsed_body.fetch("data").index_by { |row| row["id"] }
      expect(viewer_today_by_id.fetch(w2_to_1099.id)["employment_type"]).to eq("contractor")
      expect(viewer_today_by_id.fetch(contractor_to_w2.id)["employment_type"]).to eq("hourly")

      # Admin endpoint accepts a company period end date and refuses out-of-range / malformed / unrelated dates
      stub_portal_user(Api::V1::Admin::EmployeesController, staff, company)
      get "/api/v1/admin/employees", params: { status: "active", per_page: 200, rates_on: "2026-06-27" }
      expect(response).to have_http_status(:ok), response.body
      admin_june_by_id = response.parsed_body.fetch("data").index_by { |row| row["id"] }
      expect(admin_june_by_id.fetch(w2_to_1099.id)["employment_type"]).to eq("hourly")
      expect(admin_june_by_id.fetch(contractor_to_w2.id)["employment_type"]).to eq("contractor")

      get "/api/v1/admin/employees", params: { status: "active", rates_on: "9999-12-31" }
      expect(response).to have_http_status(:unprocessable_entity)

      get "/api/v1/admin/employees", params: { status: "active", rates_on: "not-a-date" }
      expect(response).to have_http_status(:unprocessable_entity)

      # Restore client manager stub for remaining submission assertions
      stub_portal_user(Api::V1::Client::EmployeesController, client_user, company)

      # Direction 1 (W-2 in June -> 1099 in July): June submission without workweek is rejected, with workweek succeeds
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: workbook_upload(week1: "45.00", week2: "35.00", target: w2_to_1099),
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: w2_to_1099.id, employee_wage_rate_id: w2_to_1099_rate.id, hours: "6.50" }
             ].to_json
           }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "changes.1").join).to include("workweek")

      # Direction 2 (1099 in June -> W-2 in July): June submission accepts straight-time hours with no workweek and applies 0 OT
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: workbook_upload(week1: "40.00", week2: "35.00", target: contractor_to_w2),
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: contractor_to_w2.id, employee_wage_rate_id: contractor_to_w2_rate.id, hours: "6.50" }
             ].to_json
           }
      expect(response).to have_http_status(:created), response.body
      sub_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: sub_id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("client_change_prefill", "rows").sole).to include(
        "extra_hours_mode" => "straight_time",
        "is_contractor" => true,
        "gross_pay_delta" => "130.00"
      )
      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id"),
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, hours: "6.50", decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body
      item = pay_period.reload.payroll_items.find_by!(employee: contractor_to_w2)
      expect(item.hours_worked).to eq(BigDecimal("81.50"))
      expect(item.overtime_hours).to eq(BigDecimal("0.00"))
      expect(item.gross_pay).to eq(BigDecimal("1630.00"))
    end

    it "matches saved gross pay to the exact cent on fractional rounding boundaries (0.01h + 0.05h @ $10.50 -> +$0.52)" do
      EmployeeCompensationChangeService.new(
        employee: employee,
        actor: staff,
        source: "spec",
        effective_on: Date.new(2026, 1, 1),
        pay_rate: BigDecimal("10.50"),
        wage_rate_edits: [ { id: primary_rate.id, rate: BigDecimal("10.50") } ]
      ).call!

      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: workbook_upload(week1: "0.01", week2: "0.00"),
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: employee.id, employee_wage_rate_id: primary_rate.id, hours: "0.05", workweek: 1 }
             ].to_json
           }
      expect(response).to have_http_status(:created), response.body
      submission_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: submission_id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      # Baseline line: round(0.01 * 10.50) = 0.11; new line: round(0.06 * 10.50) = 0.63; delta = 0.52 (not 0.53)
      expect(response.parsed_body.dig("client_change_prefill", "rows").sole).to include(
        "gross_pay_delta" => "0.52"
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id"),
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, hours: "0.05", workweek: 1, decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item = pay_period.reload.payroll_items.find_by!(employee: employee)
      expect(item.gross_pay).to eq(BigDecimal("0.63"))
      expect(item.custom_columns_data.dig("client_change_evidence", "gross_pay_delta")).to eq("0.52")
    end
  end

  describe "weekly universal workbook (single workweek — no choice needed)" do
    let(:company) do
      create(
        :company,
        organization: organization,
        name: "Synthetic Weekly Co",
        pay_frequency: "weekly",
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
        notes: "Confirmed Sunday workweek"
      )
    end
    let!(:pay_period) do
      create(
        :pay_period,
        company: company,
        company_workweek: workweek,
        start_date: Date.new(2026, 6, 14),
        end_date: Date.new(2026, 6, 20),
        pay_date: Date.new(2026, 6, 26),
        status: "draft"
      )
    end
    let!(:employee) { create(:employee, company: company, first_name: "Weekly", last_name: "Worker", pay_rate: 20.00) }
    let!(:primary_rate) do
      employee.employee_wage_rates.find_by(is_primary: true) ||
        employee.employee_wage_rates.create!(label: "Primary", rate: 20.00, is_primary: true, active: true)
    end
    let(:ref) { "#{pay_period.start_date.iso8601}_#{pay_period.end_date.iso8601}" }

    before do
      setup_tax_config(2026)
      allow(PayrollSubmissions::Catalog).to receive(:today).and_return(Date.new(2026, 6, 21))
      stub_portal_user(Api::V1::Client::PayrollSubmissionPeriodsController, client_user, company)
      stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
    end

    it "auto-selects the single workweek without asking and recomputes OT across 40 hours" do
      csv_body = CSV.generate do |csv|
        csv << PayrollIntake::UniversalWorkbook::Template::COLUMNS
        csv << [ employee.id, employee.full_name, "38.00", "", "", "", "", "", "", "", "", "", "", "", "", "" ]
      end
      upload = portal_upload("weekly.csv", csv_body, csv_mime)

      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             payroll_workbook: upload,
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: employee.id, employee_wage_rate_id: primary_rate.id, hours: "5.00" }
             ].to_json
           }
      expect(response).to have_http_status(:created), response.body
      submission_id = response.parsed_body.dig("data", "submissions", 0, "id")
      expect(response.parsed_body.dig("data", "submissions", 0, "changes", 0)).to include("workweek" => 1)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: submission_id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      prefill = response.parsed_body.dig("client_change_prefill", "rows").sole
      expect(prefill).to include(
        "extra_hours_mode" => "workweek",
        "workweek" => 1,
        "needs_classification" => false,
        "resulting_regular_hours" => "40.0",
        "resulting_overtime_hours" => "3.0",
        "gross_pay_delta" => "130.00" # +2 reg ($40) + 3 OT ($90) = $130
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id"),
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, hours: "5.00", decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item = pay_period.reload.payroll_items.find_by!(employee: employee)
      expect(item.hours_worked).to eq(BigDecimal("40.00"))
      expect(item.overtime_hours).to eq(BigDecimal("3.00"))
      expect(item.gross_pay).to eq(BigDecimal("890.00")) # 40 * $20 + 3 * $30
    end
  end

  describe "source_reports company (MoSa Revel)" do
    let(:company) do
      create(
        :company,
        organization: organization,
        name: "Synthetic Source Reports Co",
        pay_frequency: "biweekly",
        payroll_intake_source_types: [ "mosa_revel" ],
        payroll_intake_settings: { "mosa_revel" => { "required_sources" => [ "revel_hours" ] } }
      )
    end
    let(:staff) { create(:user, organization: organization, company: company, role: "admin") }
    let(:client_user) do
      user = create(:user, organization: organization, company: company, role: "client")
      CompanyAssignment.create!(user: user, company: company)
      user
    end
    let!(:pay_period) do
      create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 6, 14),
        end_date: Date.new(2026, 6, 27),
        pay_date: Date.new(2026, 7, 3),
        status: "draft"
      )
    end
    let!(:workweek) do
      CompanyWorkweek.create!(
        company: company,
        starts_on_weekday: pay_period.start_date.wday,
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
    let!(:employee) { create(:employee, company: company, first_name: "Avery", last_name: "Example", pay_rate: 20.00) }
    let!(:job) { create(:employee_wage_rate, employee: employee, label: "Service", rate: 20.00, is_primary: true) }
    let(:ref) { "#{pay_period.start_date.iso8601}_#{pay_period.end_date.iso8601}" }

    before do
      setup_tax_config(2026)
      allow(PayrollSubmissions::Catalog).to receive(:today).and_return(Date.new(2026, 6, 28))
      stub_portal_user(Api::V1::Client::PayrollSubmissionPeriodsController, client_user, company)
      stub_portal_user(Api::V1::Admin::PayrollImportsController, staff, company)
    end

    def revel_pdf_upload(regular:, overtime:)
      bytes = File.binread(build_revel_pdf(
        [ { name: "Example, Avery", regular_hours: regular, overtime_hours: overtime, regular_pay: 9999 } ],
        period_start: pay_period.start_date,
        period_end: pay_period.end_date
      ))
      portal_upload("revel.pdf", bytes, pdf_mime)
    end

    it "applies 4 regular + 2.5 OT extra hours: +4 reg, +2.5 OT, gross +$80 + $75 (+$155.00) at $20/hr" do
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             revel_payroll: revel_pdf_upload(regular: 70, overtime: 2),
             workbook_choice: "none",
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: employee.id, employee_wage_rate_id: job.id, regular_hours: "4", overtime_hours: "2.5" }
             ].to_json
           }
      expect(response).to have_http_status(:created), response.body
      submission_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: submission_id }, as: :json
      expect(response).to have_http_status(:ok), response.body

      prefill = response.parsed_body.dig("client_change_prefill", "rows").sole
      expect(prefill).to include(
        "extra_hours_mode" => "split",
        "regular_hours" => "4",
        "overtime_hours" => "2.5",
        "needs_classification" => false,
        "delta_regular_hours" => "4.0",
        "delta_overtime_hours" => "2.5",
        "resulting_regular_hours" => "74.0",
        "resulting_overtime_hours" => "4.5",
        "gross_pay_delta" => "155.00"
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id"),
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, regular_hours: "4", overtime_hours: "2.5", decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item = pay_period.reload.payroll_items.find_by!(employee: employee)
      # Baseline: 70 reg ($1,400) + 2 OT ($60) = $1,460.00
      # Extra: +4 reg ($80) + 2.5 OT ($75) = +$155.00 -> $1,615.00 gross
      expect(item.hours_worked).to eq(BigDecimal("74.00"))
      expect(item.overtime_hours).to eq(BigDecimal("4.50"))
      expect(item.gross_pay).to eq(BigDecimal("1615.00"))
      expect(item.wage_rate_hours.sole).to include("regular_hours" => 74.0, "overtime_hours" => 4.5)
      expect(item.custom_columns_data["client_change_evidence"]).to include(
        "hours_mode" => "split",
        "delta_regular_hours" => "4.0",
        "delta_overtime_hours" => "2.5",
        "gross_pay_delta" => "155.00",
        "applied_regular_hours" => "74.0",
        "applied_overtime_hours" => "4.5"
      )
    end

    it "rejects bare hours without regular/overtime split on source_reports portal submissions and legacy pending apply" do
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             revel_payroll: revel_pdf_upload(regular: 70, overtime: 2),
             workbook_choice: "none",
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: employee.id, employee_wage_rate_id: job.id, hours: "6.5" }
             ].to_json
           }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "changes.1").join).to include("regular hours")

      # Legacy pending submission with no split forces staff to choose
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             revel_payroll: revel_pdf_upload(regular: 70, overtime: 2),
             workbook_choice: "none",
             no_changes: "true",
             changes: "[]"
           }
      expect(response).to have_http_status(:created), response.body
      submission = PayrollSubmission.find(response.parsed_body.dig("data", "submissions", 0, "id"))
      submission.update_columns(
        no_changes: false,
        change_rows: [
          {
            "kind" => "extra_hours",
            "employee_id" => employee.id,
            "employee_wage_rate_id" => job.id,
            "wage_rate" => "20.0",
            "wage_rate_label" => "Service",
            "hours" => "6.5"
          }
        ]
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: submission.id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("client_change_prefill", "rows").sole).to include("needs_classification" => true)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id"),
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, hours: "6.5", decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Split")
    end

    it "restores baseline overtime and job allocations exactly when a replacement revision withdraws nonzero client OT" do
      # Also add a file-absent worker with pre-existing regular + OT baseline to exercise restore_client_hours_baseline!
      absent_worker = create(:employee, company: company, first_name: "Baseline", last_name: "Absent", pay_rate: 20.00)
      absent_job = create(:employee_wage_rate, employee: absent_worker, label: "Support", rate: 20.00, is_primary: true)
      baseline_absent_item = create(:payroll_item,
                                    company: company,
                                    pay_period: pay_period,
                                    employee: absent_worker,
                                    pay_rate: 20.00,
                                    hours_worked: 2.0,
                                    overtime_hours: 1.0,
                                    import_source: "mosa_revel",
                                    wage_rate_hours: [
                                      { employee_wage_rate_id: absent_job.id, label: "Support", rate: 20.0, regular_hours: 2.0, overtime_hours: 1.0, holiday_hours: 0.0, pto_hours: 0.0, is_primary: true, active: true }
                                    ])
      baseline_absent_item.calculate!
      baseline_absent_item.save!
      expected_absent_allocations = baseline_absent_item.reload.wage_rate_hours.deep_dup
      expect(baseline_absent_item.gross_pay).to eq(BigDecimal("70.00"))

      pdf_bytes = File.binread(build_revel_pdf(
        [ { name: "Example, Avery", regular_hours: 70, overtime_hours: 2, regular_pay: 9999 } ],
        period_start: pay_period.start_date,
        period_end: pay_period.end_date
      ))

      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             revel_payroll: portal_upload("revel.pdf", pdf_bytes, pdf_mime),
             workbook_choice: "none",
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: employee.id, employee_wage_rate_id: job.id, regular_hours: "4", overtime_hours: "2.5" },
               { kind: "extra_hours", employee_id: absent_worker.id, employee_wage_rate_id: absent_job.id, regular_hours: "3", overtime_hours: "1.5" }
             ].to_json
           }
      expect(response).to have_http_status(:created), response.body
      rev1_id = response.parsed_body.dig("data", "submissions", 0, "id")
      rev1_doc_id = response.parsed_body.dig("data", "submissions", 0, "documents", 0, "document", "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: rev1_id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id"),
             confirm_client_changes: true,
             reviewed_changes: [
               { change_index: 0, regular_hours: "4", overtime_hours: "2.5", decision: "apply" },
               { change_index: 1, regular_hours: "3", overtime_hours: "1.5", decision: "apply" }
             ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      present_item = pay_period.reload.payroll_items.find_by!(employee: employee)
      absent_item = pay_period.payroll_items.find_by!(employee: absent_worker)
      expect(present_item.hours_worked).to eq(BigDecimal("74.00"))
      expect(present_item.overtime_hours).to eq(BigDecimal("4.50"))
      expect(absent_item.hours_worked).to eq(BigDecimal("5.00"))
      expect(absent_item.overtime_hours).to eq(BigDecimal("2.50"))

      # Revision 2 keeps byte-identical PDF and withdraws both extra-hours changes
      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             based_on_revision: 1,
             keep_document_ids: [ rev1_doc_id ],
             workbook_choice: "none",
             no_changes: "true",
             changes: "[]"
           }
      expect(response).to have_http_status(:created), response.body
      rev2_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: rev2_id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id"),
             confirm_client_changes: true,
             reviewed_changes: []
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      present_item.reload
      absent_item.reload
      expect(present_item.hours_worked).to eq(BigDecimal("70.00"))
      expect(present_item.overtime_hours).to eq(BigDecimal("2.00"))
      expect(present_item.gross_pay).to eq(BigDecimal("1460.00"))
      expect(present_item.wage_rate_hours).to eq([])
      expect(present_item.custom_columns_data["client_change_evidence"]).to be_nil

      expect(absent_item.hours_worked).to eq(BigDecimal("2.00"))
      expect(absent_item.overtime_hours).to eq(BigDecimal("1.00"))
      expect(absent_item.gross_pay).to eq(BigDecimal("70.00"))
      expect(absent_item.wage_rate_hours).to eq(expected_absent_allocations)
      expect(absent_item.custom_columns_data["client_change_evidence"]).to be_nil
    end

    it "computes exact gross delta for rates with more than two decimal places ($20.125/hr, 2 OT -> +$60.38)" do
      # Schema stores scale: 6 rates (e.g. imported/legacy rates like $20.125/hr).
      employee.update_columns(pay_rate: BigDecimal("20.125"))
      employee.employee_compensation_changes.update_all(pay_rate: BigDecimal("20.125"))
      job.update_columns(rate: BigDecimal("20.125"))
      job.employee_wage_rate_versions.update_all(rate: BigDecimal("20.125"))

      post "/api/v1/client/payroll_submission_periods/#{ref}/submissions",
           params: {
             revel_payroll: revel_pdf_upload(regular: 40, overtime: 0),
             workbook_choice: "none",
             no_changes: "false",
             changes: [
               { kind: "extra_hours", employee_id: employee.id, employee_wage_rate_id: job.id, regular_hours: "0", overtime_hours: "2" }
             ].to_json
           }
      expect(response).to have_http_status(:created), response.body
      submission_id = response.parsed_body.dig("data", "submissions", 0, "id")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_import", params: { submission_id: submission_id }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("client_change_prefill", "rows").sole).to include(
        "wage_rate" => "20.125",
        "gross_pay_delta" => "60.38"
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_import",
           params: {
             import_id: response.parsed_body.fetch("import_id"),
             portal_source_id: response.parsed_body.dig("portal_source", "selection_id"),
             confirm_client_changes: true,
             reviewed_changes: [ { change_index: 0, regular_hours: "0", overtime_hours: "2", decision: "apply" } ]
           },
           as: :json
      expect(response).to have_http_status(:ok), response.body

      item = pay_period.reload.payroll_items.find_by!(employee: employee)
      expect(item.hours_worked).to eq(BigDecimal("40.00"))
      expect(item.overtime_hours).to eq(BigDecimal("2.00"))
      expect(item.custom_columns_data.dig("client_change_evidence", "gross_pay_delta")).to eq("60.38")
    end
  end
end
