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
    expect(response.parsed_body["pay_stubs"].map { |row| row["id"] }).to eq([ item.id ])
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

  it "matches the staff statement using stored YTD without changing any payroll data", :freeze_time do
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
    expect(text).to include("10,089", "1,234")
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

  it "refuses staff in the client namespace" do
    user.update!(role: "accountant")
    get "/api/v1/client/pay_stubs/#{item.id}/download", headers: headers
    expect(response).to have_http_status(:forbidden)
  end
end
