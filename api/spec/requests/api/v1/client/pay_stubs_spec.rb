# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Client pay stubs", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around(:each, :freeze_time) { |example| freeze_time { example.run } }
  let(:company) { create(:company) }
  let(:user) { create(:user, role: "client", company: company) }
  let(:employee) { create(:employee, company: company) }
  let(:period) do
    create(:pay_period, :committed, company: company, start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 14), pay_date: Date.new(2026, 4, 18))
  end
  let!(:item) { create(:payroll_item, company: company, employee: employee, pay_period: period, gross_pay: 100, net_pay: 90) }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }

  before do
    CompanyAssignment.create!(user: user, company: company)
    allow_any_instance_of(ApplicationController).to receive(:current_user) { User.find(user.id) }
  end

  it "lists finished history, renders a fresh employee statement and audits each read" do
    get "/api/v1/client/pay_stubs/employee/#{employee.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("pay_stubs").sole).to include(
      "id" => item.id, "start_date" => "2026-04-01", "end_date" => "2026-04-14")
    2.times do
      get "/api/v1/client/pay_stubs/#{item.id}/download", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.headers["Cache-Control"]).to include("no-store")
    end
    logs = AuditLog.where(action: "client_pay_stubs#download", user: user, company: company)
    expect(logs.count).to eq(2)
    expect(logs.pluck(:event_category)).to eq(%w[document_access document_access])
    expect(logs.last.metadata).to include("employee_id" => employee.id, "pay_period_id" => period.id)
    text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join
    expect(text).to include(employee.full_name)
    expect(text).not_to match(/accountant.only|review warning|storage.key|transmittal/i)
  end

  it "logs ambiguous stub history and returns a client-safe download error" do
    error = PayrollInsuranceComponents::AmbiguousHistoryError.new("Staff-only insurance repair instructions")
    allow_any_instance_of(PayStubGenerator).to receive(:generate).and_raise(error)
    expect(Rails.error).to receive(:report).with(error, handled: true, context: {
      company_id: company.id, action: "download"
    }).and_call_original

    get "/api/v1/client/pay_stubs/#{item.id}/download", headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to eq("error" => "Payroll details are unavailable right now. Contact Cornerstone.")
  end

  it "rejects other companies and foreign employee history" do
    other = create(:payroll_item)
    get "/api/v1/client/pay_stubs/#{other.id}/download", headers: headers
    expect(response).to have_http_status(:not_found)
    get "/api/v1/client/pay_stubs/employee/#{other.employee_id}", headers: headers
    expect(response).to have_http_status(:not_found)
    get "/api/v1/client/pay_stubs/#{item.id}/download", headers: { "X-Company-Id" => other.company_id.to_s }
    expect(response).to have_http_status(:forbidden)
  end

  %w[draft calculated approved].each do |status|
    it "refuses #{status} payroll" do
      period.update_columns(status: status)
      get "/api/v1/client/pay_stubs/#{item.id}/download", headers: headers
      expect(response).to have_http_status(:not_found)
      get "/api/v1/client/pay_stubs/employee/#{employee.id}", headers: headers
      expect(response.parsed_body["pay_stubs"]).to eq([])
    end
  end

  it "permits copied baselines but refuses an archived practice copy" do
    source = create(:company, organization: company.organization)
    source_period = create(:pay_period, :committed, company: source)
    company.update!(payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
      migration_source_company: source, migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now)
    user.update!(practice_company_id: company.id)
    period.update_columns(status: "approved", test_workspace_role: "baseline", test_workspace_source_pay_period_id: source_period.id)
    get "/api/v1/client/pay_stubs/#{item.id}/download", headers: headers
    expect(response).to have_http_status(:ok)
    company.update_columns(test_workspace_archived_at: Time.current)
    get "/api/v1/client/pay_stubs/#{item.id}/download", headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "matches the staff statement using live YTD without changing any payroll data", :freeze_time do
    source = create(:company, organization: company.organization)
    source_period = create(:pay_period, :committed, company: source)
    company.update!(payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
      migration_source_company: source, migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now)
    user.update!(practice_company_id: company.id)
    prior = create(:pay_period, company: company, start_date: period.start_date - 30.days,
      end_date: period.end_date - 30.days, pay_date: period.pay_date - 30.days)
    prior.update_columns(status: "approved")
    create(:payroll_item, company: company, employee: employee, pay_period: prior, gross_pay: 9999, net_pay: 9999)
    period.update_columns(status: "approved", test_workspace_role: "baseline", test_workspace_source_pay_period_id: source_period.id)
    item.update_columns(ytd_gross: 10099, ytd_net: 10089, ytd_withholding_tax: 1234)
    before_items = PayrollItem.order(:id).map(&:attributes)
    before_periods = PayPeriod.order(:id).map(&:attributes)
    get "/api/v1/client/pay_stubs/#{item.id}/download", headers: headers
    expect(response).to have_http_status(:ok)
    expect(PayrollItem.order(:id).map(&:attributes)).to eq(before_items)
    expect(PayPeriod.order(:id).map(&:attributes)).to eq(before_periods)
    text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join
    staff_text = PDF::Reader.new(StringIO.new(PayStubGenerator.new(item.reload).generate)).pages.map(&:text).join
    expect(text).to eq(staff_text)
    # Saved snapshots are left alone; the statement prints the live totals.
    expect(text).to include("10,089")
    expect(text).not_to include("1,234")
    expect(item.reload.ytd_gross.to_f).to eq(10099)
    expect(item.ytd_net.to_f).to eq(10089)
  end

  it "omits empty statements from history and period controls and refuses their download" do
    empty_employee = create(:employee, company: company)
    empty = create(:payroll_item, company: company, employee: empty_employee, pay_period: period, gross_pay: 0, net_pay: 0)
    get "/api/v1/client/pay_stubs/employee/#{empty_employee.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["pay_stubs"]).to eq([])
    expect { get "/api/v1/client/pay_stubs/#{empty.id}/download", headers: headers }.not_to change { AuditLog.where(action: "client_pay_stubs#download").count }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("no earnings activity")
    get "/api/v1/client/pay_periods/#{period.id}", headers: headers
    expect(response).to have_http_status(:ok)
    rows = response.parsed_body.fetch("pay_period").fetch("payroll_items")
    expect(rows.find { |row| row["id"] == empty.id }["pay_stub_available"]).to be(false)
    expect(rows.find { |row| row["id"] == item.id }["pay_stub_available"]).to be(true)
  end

  it "includes locked QuickBooks checks only for the client's own company employee without exposing sensitive fields" do
    batch = HistoricalImportBatch.create!(
      company: company,
      source_label: "QuickBooks 2026",
      bundle_digest: "qb-client-stubs-#{company.id}",
      importer_version: "quickbooks-online-payroll-v5",
      status: "locked",
      locked_at: Time.zone.parse("2026-03-21 09:00"),
      locked_by: user
    )
    historical_period = HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: company,
      external_key: "qb-period-1",
      source_label: "Feb 2026",
      start_date: Date.new(2026, 2, 1),
      end_date: Date.new(2026, 2, 14),
      pay_date: Date.new(2026, 2, 19),
      paycheck_count: 1
    )
    worker = HistoricalWorker.create!(
      historical_import_batch: batch,
      company: company,
      employee: employee,
      external_key: "qb-worker-1",
      source_name: employee.full_name,
      normalized_name: employee.full_name.downcase,
      source_status: "active",
      mapping_status: "exact_match"
    )
    qb_check = HistoricalPaycheck.create!(
      historical_import_batch: batch,
      historical_pay_period: historical_period,
      historical_worker: worker,
      company: company,
      employee: employee,
      external_key: "qb-check-1",
      source_employee_name: employee.full_name,
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: "matched",
      period_start: historical_period.start_date,
      period_end: historical_period.end_date,
      pay_date: historical_period.pay_date,
      check_number: "QB-9991",
      payment_method: "Direct deposit",
      hours_total: 80,
      gross_pay: 1600,
      net_pay: 1320.50,
      source_metadata: { "private_note" => "internal only" }
    )

    unlocked_batch = HistoricalImportBatch.create!(
      company: company,
      source_label: "QuickBooks Draft",
      bundle_digest: "qb-client-stubs-draft-#{company.id}",
      importer_version: "quickbooks-online-payroll-v5",
      status: "applied"
    )
    unlocked_period = HistoricalPayPeriod.create!(
      historical_import_batch: unlocked_batch,
      company: company,
      external_key: "qb-period-draft",
      source_label: "Jan 2026",
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 1, 14),
      pay_date: Date.new(2026, 1, 19),
      paycheck_count: 1
    )
    unlocked_worker = HistoricalWorker.create!(
      historical_import_batch: unlocked_batch,
      company: company,
      employee: employee,
      external_key: "qb-worker-draft",
      source_name: employee.full_name,
      normalized_name: employee.full_name.downcase,
      source_status: "active",
      mapping_status: "exact_match"
    )
    HistoricalPaycheck.create!(
      historical_import_batch: unlocked_batch,
      historical_pay_period: unlocked_period,
      historical_worker: unlocked_worker,
      company: company,
      employee: employee,
      external_key: "qb-check-draft",
      source_employee_name: employee.full_name,
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: "matched",
      period_start: unlocked_period.start_date,
      period_end: unlocked_period.end_date,
      pay_date: unlocked_period.pay_date,
      gross_pay: 1500,
      net_pay: 1200
    )

    other_company = create(:company)
    other_employee = create(:employee, company: other_company)
    create(:pay_period, :committed, company: other_company, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 4, 14), pay_date: Date.new(2026, 4, 18))
    other_batch = HistoricalImportBatch.create!(
      company: other_company,
      source_label: "Other QuickBooks",
      bundle_digest: "qb-other-#{other_company.id}",
      importer_version: "quickbooks-online-payroll-v5",
      status: "locked",
      locked_at: Time.zone.parse("2026-03-21 09:00")
    )
    other_period = HistoricalPayPeriod.create!(
      historical_import_batch: other_batch,
      company: other_company,
      external_key: "other-period",
      source_label: "Feb 2026",
      start_date: Date.new(2026, 2, 1),
      end_date: Date.new(2026, 2, 14),
      pay_date: Date.new(2026, 2, 19),
      paycheck_count: 1
    )
    other_worker = HistoricalWorker.create!(
      historical_import_batch: other_batch,
      company: other_company,
      employee: other_employee,
      external_key: "other-worker",
      source_name: other_employee.full_name,
      normalized_name: other_employee.full_name.downcase,
      source_status: "active",
      mapping_status: "exact_match"
    )
    HistoricalPaycheck.create!(
      historical_import_batch: other_batch,
      historical_pay_period: other_period,
      historical_worker: other_worker,
      company: other_company,
      employee: other_employee,
      external_key: "other-check",
      source_employee_name: other_employee.full_name,
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: "matched",
      period_start: other_period.start_date,
      period_end: other_period.end_date,
      pay_date: other_period.pay_date,
      gross_pay: 2100,
      net_pay: 1700
    )

    get "/api/v1/client/pay_stubs/employee/#{employee.id}", headers: headers
    expect(response).to have_http_status(:ok)
    qb_rows = response.parsed_body.fetch("quickbooks_paychecks")
    expect(qb_rows.size).to eq(1)
    expect(qb_rows.first).to include(
      "id" => qb_check.id,
      "pay_date" => "2026-02-19",
      "period_start" => "2026-02-01",
      "period_end" => "2026-02-14",
      "source_label" => "From QuickBooks records"
    )
    expect(qb_rows.first["net_pay"].to_d).to eq(1320.50.to_d)
    expect(qb_rows.first).not_to have_key("payment_method")
    expect(response.body).not_to include("QB-9991", "internal only", "Direct deposit")

    get "/api/v1/client/pay_stubs/employee/#{other_employee.id}", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "refuses staff in the client namespace" do
    user.update!(role: "accountant")
    get "/api/v1/client/pay_stubs/#{item.id}/download", headers: headers
    expect(response).to have_http_status(:forbidden)
  end
end
