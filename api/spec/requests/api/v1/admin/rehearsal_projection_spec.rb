# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Migration rehearsal payroll projection", type: :request do
  let!(:source_company) { create(:company) }
  let!(:source_batch) { create(:historical_import_batch, company: source_company, status: "locked", locked_at: Time.current) }
  let!(:company) do
    create(:company,
      organization: source_company.organization,
      payroll_environment: "migration_rehearsal",
      migration_source_company: source_company,
      migration_source_batch: source_batch,
      migration_rehearsal_status: "ready")
  end
  let!(:department) { create(:department, company: company) }
  let!(:employee) { create(:employee, company: company, department: department) }
  let!(:actor) { create(:user, company: company, organization: company.organization) }
  let!(:first_period) do
    create(:pay_period, :calculated, company: company,
      start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 14), pay_date: Date.new(2026, 1, 16))
  end
  let!(:second_period) do
    create(:pay_period, :calculated, company: company,
      start_date: Date.new(2026, 1, 15), end_date: Date.new(2026, 1, 28), pay_date: Date.new(2026, 1, 30))
  end
  let!(:draft_period) do
    create(:pay_period, company: company,
      start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 14), pay_date: Date.new(2026, 2, 16))
  end

  before do
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(actor)
    create(:payroll_item, company: company, employee: employee, pay_period: first_period, gross_pay: 100, net_pay: 80)
    create(:payroll_item, company: company, employee: employee, pay_period: second_period, gross_pay: 200, net_pay: 160)
    create(:payroll_item, company: company, employee: employee, pay_period: draft_period, gross_pay: 900, net_pay: 720)
  end

  it "reports calculated rehearsal runs but never draft rows as provisional, unpaid totals" do
    get "/api/v1/admin/reports/ytd_summary", params: { start_date: "2026-01-01", end_date: "2026-02-28" }

    expect(response).to have_http_status(:ok)
    report = response.parsed_body.fetch("report")
    expect(report.dig("meta", "provisional")).to be(true)
    expect(report.dig("meta", "payroll_status_note")).to include("not committed or paid")
    expect(report.fetch("employees").find { |row| row.fetch("employee_id") == employee.id }.fetch("gross_pay")).to eq(300.0)
  end

  it "uses prior calculated runs for cumulative math, and invalidates later projections when an earlier run changes" do
    expect(employee.ytd_totals_before(year: 2026, pay_date: second_period.pay_date, pay_period_id: second_period.id)[:gross_pay]).to eq(100.0)

    first_period.invalidate_calculation!(reason: "Earlier rehearsal inputs changed")

    expect(second_period.reload).to be_draft
    expect(employee.ytd_totals_before(year: 2026, pay_date: second_period.pay_date, pay_period_id: second_period.id)[:gross_pay]).to eq(0.0)
  end

  it "marks CSV exports as test-only in the filename and every employee row" do
    get "/api/v1/admin/reports/ytd_summary_csv", params: { year: 2026 }

    expect(response).to have_http_status(:ok)
    expect(response.headers.fetch("Content-Disposition")).to include("test_only_payroll_summary_2026.csv")
    rows = CSV.parse(response.body, headers: true)
    expect(rows.headers).to include("Payroll status")
    expect(rows.first.fetch("Payroll status")).to include("TEST ONLY")
  end
end
