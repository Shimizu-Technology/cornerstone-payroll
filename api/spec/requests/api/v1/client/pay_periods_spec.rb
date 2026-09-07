# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Client::PayPeriods", type: :request do
  let!(:company) { create(:company, name: "Portal Payroll Co") }
  let!(:client_user) { create(:user, company: company, role: "client", email: "portal-pay-periods@example.com") }
  let!(:committed_pay_period) do
    create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 14),
      pay_date: Date.new(2026, 4, 18))
  end
  let!(:draft_pay_period) do
    create(:pay_period,
      company: company,
      status: "draft",
      start_date: Date.new(2026, 4, 15),
      end_date: Date.new(2026, 4, 28),
      pay_date: Date.new(2026, 5, 2))
  end

  before do
    CompanyAssignment.create!(user: client_user, company: company)
    create(:employee, company: company, first_name: "Nina", last_name: "Cruz")
    create(:payroll_item, pay_period: committed_pay_period, company: company, gross_pay: 1000, net_pay: 810)
    create(:payroll_item, pay_period: draft_pay_period, company: company, gross_pay: 900, net_pay: 730)

    [
      Api::V1::Client::PayPeriodsController,
      Api::V1::Client::ImportedPayPeriodsController
    ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(client_user)
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    end
  end

  def create_imported_payroll(company:, status: "locked", suffix: "client", pay_date: Date.new(2026, 3, 20))
    employee = company.employees.first || create(:employee, company: company)
    batch = HistoricalImportBatch.create!(
      company: company,
      source_label: "QuickBooks #{suffix}",
      bundle_digest: "client-pay-periods-#{company.id}-#{suffix}",
      importer_version: "quickbooks-online-payroll-v5",
      status: status,
      locked_at: status == "locked" ? Time.zone.parse("2026-03-21 09:00") : nil,
      locked_by: status == "locked" ? client_user : nil
    )
    period = HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: company,
      external_key: "period-#{suffix}",
      source_label: "Payroll #{suffix}",
      start_date: pay_date - 13.days,
      end_date: pay_date - 5.days,
      pay_date: pay_date,
      paycheck_count: 1,
      totals: { "gross_pay" => "875.25", "net_pay" => "701.10" }
    )
    worker = HistoricalWorker.create!(
      historical_import_batch: batch,
      company: company,
      employee: employee,
      external_key: "worker-#{suffix}",
      source_name: "Nina Cruz",
      normalized_name: "nina cruz",
      source_status: "active",
      mapping_status: "exact_match"
    )
    paycheck = HistoricalPaycheck.create!(
      historical_import_batch: batch,
      historical_pay_period: period,
      historical_worker: worker,
      company: company,
      employee: employee,
      external_key: "check-#{suffix}",
      source_employee_name: "Nina Cruz",
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: "matched",
      period_start: period.start_date,
      period_end: period.end_date,
      pay_date: period.pay_date,
      check_number: "QB-401",
      payment_method: "Direct deposit",
      hours_total: 72,
      gross_pay: 875.25,
      employee_taxes: 124.15,
      federal_income_tax: 70,
      social_security_tax: 45,
      medicare_tax: 9.15,
      after_tax_deductions: 50,
      net_pay: 701.10,
      source_metadata: { "private_note" => "never expose this" }
    )
    [ batch, period, paycheck ]
  end

  it "shows only reportable Cornerstone payrolls and locked QuickBooks payrolls" do
    _batch, imported_period, = create_imported_payroll(company: company)
    create_imported_payroll(company: company, status: "applied", suffix: "not-locked")
    hidden_void = create(:pay_period, :committed, company: company, correction_status: "voided")

    get "/api/v1/client/pay_periods"

    expect(response).to have_http_status(:ok)
    records = response.parsed_body.fetch("pay_periods")
    expect(records.map { |record| record.fetch("key") }).to contain_exactly(
      "native:#{committed_pay_period.id}",
      "imported:#{imported_period.id}"
    )
    expect(records.map { |record| record.fetch("key") }).not_to include("native:#{hidden_void.id}")
    expect(records.find { |record| record.fetch("record_type") == "imported" }).to include(
      "status" => "locked",
      "total_gross" => 875.25,
      "total_net" => 701.1,
      "capabilities" => include("view" => true, "edit" => false, "delete" => false, "run" => false)
    )
    expect(response.parsed_body.dig("meta", "statuses")).to eq("committed" => 1, "locked" => 1)
  end

  it "orders payroll history newest first" do
    march_period = create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 3, 16),
      end_date: Date.new(2026, 3, 31),
      pay_date: Date.new(2026, 4, 20))
    earlier_march_period = create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 15),
      pay_date: Date.new(2026, 3, 30))

    get "/api/v1/client/pay_periods"

    ids = response.parsed_body.fetch("pay_periods").map { |pay_period| pay_period.fetch("id") }
    expect(ids).to eq([ committed_pay_period.id, march_period.id, earlier_march_period.id ])
  end

  it "shows a safe read-only QuickBooks payroll detail" do
    _batch, imported_period, paycheck = create_imported_payroll(company: company, suffix: "detail")

    get "/api/v1/client/imported_pay_periods/#{imported_period.id}"

    expect(response).to have_http_status(:ok), response.body
    body = response.parsed_body
    expect(body.dig("data", "key")).to eq("imported:#{imported_period.id}")
    expect(body.dig("data", "capabilities")).to include(
      "view" => true,
      "edit" => false,
      "delete" => false,
      "run" => false,
      "commit" => false
    )
    expect(body.dig("data", "paychecks").sole).to include(
      "id" => paycheck.id,
      "historical_pay_period_id" => imported_period.id,
      "historical_worker_id" => paycheck.historical_worker_id,
      "employee_name" => "Nina Cruz",
      "pay_date" => imported_period.pay_date.iso8601,
      "period_type" => "regular",
      "payment_method" => "Direct deposit",
      "check_number" => nil
    )
    expect(body.dig("data", "source")).not_to have_key("import_batch_id")
    expect(body.dig("data", "source")).not_to have_key("importer_version")
    expect(body.dig("data", "source")).not_to have_key("locked_by_name")
    expect(response.body).not_to include("QB-401", "private_note", "never expose this")
  end

  it "does not expose unlocked or another company's imported payroll" do
    _batch, applied_period, = create_imported_payroll(company: company, status: "applied", suffix: "applied-detail")
    other_company = create(:company)
    _other_batch, other_period, = create_imported_payroll(company: other_company, suffix: "other-company")

    get "/api/v1/client/imported_pay_periods/#{applied_period.id}"
    expect(response).to have_http_status(:not_found)

    get "/api/v1/client/imported_pay_periods/#{other_period.id}"
    expect(response).to have_http_status(:not_found)
  end

  it "returns not found for a non-numeric imported payroll id" do
    get "/api/v1/client/imported_pay_periods/not-a-number"

    expect(response).to have_http_status(:not_found)
  end

  it "does not allow a client to open a draft pay period detail" do
    get "/api/v1/client/pay_periods/#{draft_pay_period.id}"

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => "Pay period not found")
  end
end
