# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollHistory", type: :request do
  let!(:company) { create(:company, historical_payroll_enabled: false) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin", name: "Payroll Admin") }
  let(:current_actor) { admin }

  before do
    [
      Api::V1::Admin::PayrollHistoryController,
      Api::V1::Admin::ImportedPayPeriodsController
    ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(current_actor)
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    end
  end

  def create_batch(company:, status:, suffix:, actor: admin)
    HistoricalImportBatch.create!(
      company: company,
      source_label: "QuickBooks #{suffix}",
      bundle_digest: "bundle-#{suffix}",
      importer_version: "quickbooks-online-payroll-v5",
      status: status,
      locked_at: status == "locked" ? Time.zone.parse("2024-03-20 09:00") : nil,
      locked_by: status == "locked" ? actor : nil
    )
  end

  def create_historical_period(batch:, suffix:, pay_date:, period_type: "regular", totals: {})
    HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: batch.company,
      external_key: "period-#{suffix}",
      source_label: "Payroll #{suffix}",
      start_date: pay_date - 13.days,
      end_date: pay_date - 5.days,
      pay_date: pay_date,
      paycheck_count: 1,
      period_type: period_type,
      totals: { "gross_pay" => "1200.50", "net_pay" => "925.25" }.merge(totals)
    )
  end

  def create_historical_paycheck(batch:, period:, suffix:, employee: nil)
    worker = HistoricalWorker.create!(
      historical_import_batch: batch,
      company: batch.company,
      employee: employee,
      external_key: "worker-#{suffix}",
      source_name: "Worker, #{suffix}",
      normalized_name: "worker #{suffix.downcase}",
      source_status: "active",
      mapping_status: employee ? "exact_match" : "archive_only"
    )
    HistoricalPaycheck.create!(
      historical_import_batch: batch,
      historical_pay_period: period,
      historical_worker: worker,
      company: batch.company,
      employee: employee,
      external_key: "check-#{suffix}",
      source_employee_name: "Worker, #{suffix}",
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: employee ? "matched" : "unmatched",
      period_start: period.start_date,
      period_end: period.end_date,
      pay_date: period.pay_date,
      hours_total: 80,
      gross_pay: 1200.50,
      adjusted_gross: 1200.50,
      employee_taxes: 200,
      federal_income_tax: 100,
      social_security_tax: 75,
      medicare_tax: 25,
      after_tax_deductions: 75.25,
      net_pay: 925.25,
      total_payroll_cost: 1300,
      source_metadata: { "private" => "must-not-leak", "storage_key" => "secret/path" }
    )
  end

  it "interleaves native payroll with only locked regular QuickBooks periods" do
    employee = create(:employee, company: company)
    native = create(:pay_period, :committed, company: company, start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 1, 14), pay_date: Date.new(2024, 1, 19), committed_by_id: admin.id)
    create(:payroll_item, pay_period: native, employee: employee, gross_pay: 900, net_pay: 700)

    locked = create_batch(company: company, status: "locked", suffix: "locked")
    imported = create_historical_period(batch: locked, suffix: "locked", pay_date: Date.new(2024, 2, 2))
    create_historical_paycheck(batch: locked, period: imported, suffix: "Locked", employee: employee)
    create_historical_period(batch: locked, suffix: "opening", pay_date: Date.new(2023, 12, 31), period_type: "opening_summary")
    applied = create_batch(company: company, status: "applied", suffix: "applied")
    create_historical_period(batch: applied, suffix: "applied", pay_date: Date.new(2024, 2, 16))

    get "/api/v1/admin/payroll_history"

    expect(response).to have_http_status(:ok), response.body
    records = response.parsed_body.fetch("data")
    expect(records.map { |record| record.fetch("key") }).to eq([ "imported:#{imported.id}", "native:#{native.id}" ])
    expect(records.first).to include(
      "status" => "locked",
      "total_gross" => 1200.5,
      "total_net" => 925.25,
      "employee_count" => 1,
      "capabilities" => include("view" => true, "edit" => false, "delete" => false, "run" => false)
    )
    expect(records.first.dig("source", "label")).to eq("QuickBooks import")
    expect(records.second.dig("source", "label")).to eq("Cornerstone")
    expect(response.parsed_body.fetch("meta")).to include(
      "total_count" => 2,
      "statuses" => include("locked" => 1, "committed" => 1),
      "years" => [ 2024 ]
    )
  end

  it "filters and paginates the union on the server" do
    batch = create_batch(company: company, status: "locked", suffix: "filters")
    first = create_historical_period(batch: batch, suffix: "Alpha", pay_date: Date.new(2023, 12, 22))
    second = create_historical_period(batch: batch, suffix: "Beta", pay_date: Date.new(2024, 1, 5))

    get "/api/v1/admin/payroll_history", params: { source: "quickbooks", status: "locked", year: 2024, search: "Beta", page: 1, per_page: 1 }

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("data").sole.fetch("id")).to eq(second.id)
    expect(response.parsed_body.fetch("meta")).to include("total_count" => 1, "total_pages" => 1)

    get "/api/v1/admin/payroll_history", params: { source: "quickbooks", sort: "pay_date", direction: "asc", page: 2, per_page: 1 }
    expect(response.parsed_body.fetch("data").sole.fetch("id")).to eq(second.id)
    expect(response.parsed_body.dig("meta", "total_count")).to eq(2)

    get "/api/v1/admin/payroll_history", params: { source: "quickbooks", sort: "pay_date", direction: "asc", page: 1, per_page: 1 }
    expect(response.parsed_body.fetch("data").sole.fetch("id")).to eq(first.id)

    get "/api/v1/admin/payroll_history", params: { source: "quickbooks", search: "Jan" }
    expect(response.parsed_body.fetch("data").sole.fetch("id")).to eq(second.id)

    get "/api/v1/admin/payroll_history", params: { source: "quickbooks", search: "Dec 9 - 17, 2023" }
    expect(response.parsed_body.fetch("data").sole.fetch("id")).to eq(first.id)
  end

  it "shows a paginated imported detail without exposing private source metadata" do
    employee = create(:employee, company: company, first_name: "Linked", last_name: "Worker")
    batch = create_batch(company: company, status: "locked", suffix: "detail")
    period = create_historical_period(batch: batch, suffix: "detail", pay_date: Date.new(2024, 4, 5))
    paycheck = create_historical_paycheck(batch: batch, period: period, suffix: "Detail", employee: employee)

    get "/api/v1/admin/imported_pay_periods/#{period.id}", params: { page: 1, per_page: 1 }

    expect(response).to have_http_status(:ok), response.body
    body = response.parsed_body
    expect(body.dig("data", "id")).to eq(period.id)
    expect(body.dig("data", "paychecks").sole).to include(
      "id" => paycheck.id,
      "employee_name" => "Linked Worker",
      "federal_income_tax" => "100.0",
      "social_security_tax" => "75.0",
      "medicare_tax" => "25.0"
    )
    expect(body.dig("meta", "total_count")).to eq(1)
    expect(response.body).not_to include("source_metadata", "must-not-leak", "storage_key", "secret/path")
  end

  it "keeps imported payroll readable when the migration tool is disabled" do
    batch = create_batch(company: company, status: "locked", suffix: "feature-off")
    period = create_historical_period(batch: batch, suffix: "feature-off", pay_date: Date.new(2024, 5, 3))

    get "/api/v1/admin/payroll_history", params: { source: "quickbooks" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").sole.fetch("id")).to eq(period.id)
  end

  context "when the current staff member is an accountant" do
    let(:current_actor) { create(:user, company: company, organization: company.organization, role: "accountant") }

    it "allows read-only payroll history access" do
      get "/api/v1/admin/payroll_history"
      expect(response).to have_http_status(:ok)
    end
  end

  context "when the current user is a client" do
    let(:current_actor) { create(:user, company: company, organization: company.organization, role: "client") }

    it "denies access to the staff payroll-history endpoints" do
      get "/api/v1/admin/payroll_history"
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "does not return an imported period from another company" do
    other_company = create(:company, organization: company.organization)
    batch = create_batch(company: other_company, status: "locked", suffix: "other", actor: admin)
    period = create_historical_period(batch: batch, suffix: "other", pay_date: Date.new(2024, 6, 7))

    get "/api/v1/admin/imported_pay_periods/#{period.id}"

    expect(response).to have_http_status(:not_found)
  end

  it "does not expose a regular period until its import batch is locked" do
    batch = create_batch(company: company, status: "applied", suffix: "not-locked")
    period = create_historical_period(batch: batch, suffix: "not-locked", pay_date: Date.new(2024, 7, 5))

    get "/api/v1/admin/imported_pay_periods/#{period.id}"

    expect(response).to have_http_status(:not_found)
  end
end
