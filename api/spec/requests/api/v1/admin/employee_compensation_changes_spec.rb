# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Effective-dated pay changes through the admin employee API", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { ensure_verified_test_tax_years(2024, 2025, 2026) }
  around { |example| travel_to(Time.zone.parse("2026-11-20 12:00:00 +10:00")) { example.run } }

  let!(:company) { create(:company) }
  let!(:admin_user) { User.create!(company: company, email: "admin-#{company.id}@example.com", name: "Admin User", role: "admin", active: true) }
  let!(:employee) { create(:employee, company: company, pay_rate: 15, hire_date: Date.new(2026, 1, 1)) }
  let!(:rate) { employee.employee_wage_rates.create!(label: "Regular", rate: 15, is_primary: true) }
  let!(:committed) do
    create(:pay_period, :committed, company: company, start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 15), pay_date: Date.new(2026, 11, 20))
  end
  let!(:paid_item) { create(:payroll_item, company: company, pay_period: committed, employee: employee, pay_rate: 15, gross_pay: 1200, net_pay: 1000) }

  before do
    allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::EmployeesController).to receive(:current_user).and_return(admin_user)
  end

  def update_pay(**employee_params)
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: { compensation_revision: EmployeeCompensationChangeService.revision(employee.reload) }.merge(employee_params) }, as: :json
  end

  it "shows the pay rate history and the effective dates the editor offers" do
    get "/api/v1/admin/employees/#{employee.id}"

    history = response.parsed_body.dig("data", "compensation_history")
    expect(history.fetch("effective_dates")).to eq(
      "next_uncommitted_period" => "2026-11-16", "today" => "2026-11-20", "locked_through" => "2026-11-15"
    )
    expect(history.fetch("pay_rate_changes").sole).to include("effective_on" => "2026-01-01", "status" => "current", "source" => "employee_creation")
    expect(history.fetch("wage_rate_versions").sole).to include("label" => "Regular", "employee_wage_rate_id" => rate.id, "status" => "current")
  end

  it "saves the pay rate and hourly rates together from the chosen effective date" do
    update_pay(
      pay_rate: 17, compensation_effective_on: "2026-12-01", compensation_change_reason: "Annual raise",
      wage_rates: [ { id: rate.id, label: "Regular", rate: 17, is_primary: true, active: true } ]
    )

    expect(response).to have_http_status(:ok), response.body
    expect(employee.reload.pay_rate).to eq(15)
    expect(employee.default_payroll_rate_on(Date.new(2026, 11, 30))).to eq(15)
    expect(employee.default_payroll_rate_on(Date.new(2026, 12, 15))).to eq(17)
    scheduled = response.parsed_body.dig("data", "compensation_history", "pay_rate_changes").first
    expect(scheduled).to include("effective_on" => "2026-12-01", "status" => "scheduled", "reason" => "Annual raise", "created_by_name" => "Admin User")
    expect(AuditLog.where(action: "employee#compensation_changed", record_id: employee.id).sole.metadata).to include("effective_on" => "2026-12-01")
  end

  it "returns 422 for a change dated inside committed payroll and leaves the paid check alone" do
    before_item = paid_item.reload.attributes
    update_pay(pay_rate: 18, compensation_effective_on: "2026-11-10", compensation_change_reason: "Backdated raise")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include("code" => "compensation_locked_period")
    expect(response.parsed_body.dig("details", "compensation_effective_on").sole).to include("through 2026-11-15")
    expect(employee.reload.pay_rate).to eq(15)
    expect(paid_item.reload.attributes).to eq(before_item)
  end

  it "records an explicit historical correction without changing the committed stub" do
    before_item = paid_item.reload.attributes
    update_pay(pay_rate: 18, compensation_effective_on: "2026-11-10", compensation_change_reason: "Raise was agreed on Nov 10",
      compensation_historical_correction: true)

    expect(response).to have_http_status(:ok), response.body
    expect(paid_item.reload.attributes).to eq(before_item)
    expect(employee.reload.compensation_on(Date.new(2026, 11, 12))).to have_attributes(pay_rate: 18, historical_correction: true)
  end

  it "reports a mid-period change against an open payroll" do
    create(:pay_period, company: company, start_date: Date.new(2026, 11, 16), end_date: Date.new(2026, 11, 30), pay_date: Date.new(2026, 12, 4))
    update_pay(pay_rate: 16, compensation_effective_on: "2026-11-20", compensation_change_reason: "Promotion")

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("compensation_warnings").sole).to include("mid-period on 2026-11-20")
  end

  it "ignores a wage-rate list sent without an effective date, as older editors did" do
    update_pay(wage_rates: [ { id: rate.id, label: "Regular", rate: 99, is_primary: true, active: true } ])

    expect(response).to have_http_status(:ok)
    expect(rate.reload.rate).to eq(15)
  end
end
