# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Restore removed pay-run employees", type: :request do
  let(:company) { create(:company) }
  let(:staff) { create(:user, company: company, role: "accountant") }
  let(:period) { create(:pay_period, company: company, status: "calculated") }
  let(:employee) { create(:employee, company: company) }
  let!(:exclusion) { PayPeriodExcludedEmployee.create!(pay_period: period, employee: employee, reason: "No hours received", excluded_by: staff) }
  let(:url) { "/api/v1/admin/pay_periods/#{period.id}/excluded_employees/#{employee.id}" }

  before { ensure_verified_test_tax_years(2024) }
  before { stub_portal_user(Api::V1::Admin::PayPeriodExcludedEmployeesController, staff, company) }

  it "allows accountants to restore an employee and audits the actor and original reason" do
    delete url, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(period.pay_period_excluded_employees).to be_empty
    expect(period.reload).to be_calculated
    audit = AuditLog.find_by!(action: "pay_period_excluded_employees#destroy")
    expect(audit).to have_attributes(user_id: staff.id, company_id: company.id, record_id: period.id)
    expect(audit.metadata).to include("employee_id" => employee.id, "original_exclusion_reason" => "No hours received")
  end

  it "returns the removed hours field as missing, then filled after calculation" do
    ensure_verified_test_tax_years(2024)
    field = PayrollStandingChange.create!(company: company, employee: employee, kind: "extra_hours",
      employee_wage_rate: create(:employee_wage_rate, employee: employee, is_primary: true), label: "Manual hours", required: true)
    expect(PayrollExpectedEntries.new(period).payload[:fields].sole[:status]).to eq("excluded")
    delete url, as: :json
    expect(response.parsed_body.dig("expected_entries", "fields").sole).to include("status" => "missing")
    stub_portal_user(Api::V1::Admin::PayPeriodsController, staff, company)
    post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", params: {
      employee_ids: [ employee.id ], hours: { employee.id.to_s => { regular: 16, overtime: 0 } }
    }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("results", "errors")).to be_empty
    expect(PayrollExpectedEntries.new(period.reload).payload[:fields].sole).to include(id: field.id, status: "filled")
    expect(period.payroll_items.find_by!(employee: employee).gross_pay).to be_positive
  end

  it "allows restore from draft special runs" do
    period.update!(status: "draft")
    period.update!(run_purpose: "bonus")
    delete url, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(period.pay_period_excluded_employees).to be_empty
  end

  it "requires unapproval for approved runs" do
    period.update!(status: "approved")
    delete url, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Unapprove the pay run before adding someone back.")
    expect(exclusion.reload).to be_persisted
  end

  it "rejects committed runs" do
    period.update!(status: "committed", committed_at: Time.current)
    delete url, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(exclusion.reload).to be_persisted
  end

  it "rejects employees who are no longer eligible" do
    employee.update!(status: "inactive")
    delete url, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("not eligible for this run's dates")
    expect(exclusion.reload).to be_persisted
  end

  it "allows a terminated employee eligible during this period" do
    employee.update!(status: "terminated", termination_date: period.end_date)
    delete url, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(period.pay_period_excluded_employees).to be_empty
  end

  it "does not restore active employees outside this period's eligibility dates" do
    employee.update!(hire_date: period.end_date + 1.day)
    delete url, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "is idempotent without duplicate restoration audits" do
    2.times do
      delete url, as: :json
      expect(response).to have_http_status(:ok), response.body
    end
    expect(AuditLog.where(action: "pay_period_excluded_employees#destroy").count).to eq(1)
  end

  it "denies clients" do
    staff.update!(role: "client")
    delete url, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(exclusion.reload).to be_persisted
  end

  it "does not restore another company's employee or period" do
    other = create(:employee)
    delete "/api/v1/admin/pay_periods/#{period.id}/excluded_employees/#{other.id}", as: :json
    expect(response).to have_http_status(:not_found)
    other_period = create(:pay_period)
    delete "/api/v1/admin/pay_periods/#{other_period.id}/excluded_employees/#{employee.id}", as: :json
    expect(response).to have_http_status(:not_found)
    expect(exclusion.reload).to be_persisted
  end

  it "includes names and reasons in the pay-run response even for ineligible employees" do
    employee.update!(status: "inactive")
    stub_portal_user(Api::V1::Admin::PayPeriodsController, staff, company)
    get "/api/v1/admin/pay_periods/#{period.id}", as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("pay_period", "excluded_employees").sole).to include(
      "employee_id" => employee.id, "name" => employee.full_name, "reason" => "No hours received")
  end
  it "retains the removed roster in approval transition responses" do
    period.update!(status: "approved")
    stub_portal_user(Api::V1::Admin::PayPeriodsController, staff, company)
    post "/api/v1/admin/pay_periods/#{period.id}/unapprove", as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("pay_period", "excluded_employee_ids")).to eq([ employee.id ])
    expect(response.parsed_body.dig("pay_period", "excluded_employees").sole).to include("reason" => "No hours received")
  end
  %w[final correction adjustment].each do |purpose|
    it "uses explicit calculation eligibility to restore a previously terminated worker on a #{purpose} run" do
      period.update!(status: "draft")
      period.update!(run_purpose: purpose)
      employee.update!(status: "terminated", termination_date: period.start_date - 1.day)
      expect(Employee.eligible_for_period(period.start_date, period.end_date)).not_to exist(id: employee.id)
      delete url, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(period.pay_period_excluded_employees).to be_empty
    end
  end

  it "lists a restored former worker for explicit pay entry and calculates their adjustment" do
    period.update!(status: "draft")
    period.update!(run_purpose: "adjustment")
    employee.update!(status: "terminated", termination_date: period.start_date - 1.day)
    expect(period.payroll_items).to be_empty

    delete url, as: :json
    expect(response).to have_http_status(:ok), response.body
    stub_portal_user(Api::V1::Admin::EmployeesController, staff, company)
    get "/api/v1/admin/employees", params: { eligible_pay_period_id: period.id }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("data").map { |row| row.fetch("id") }).to include(employee.id)

    stub_portal_user(Api::V1::Admin::PayPeriodsController, staff, company)
    post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", params: {
      employee_ids: [ employee.id ], hours: { employee.id.to_s => { regular: 16, overtime: 0 } }
    }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("results", "errors")).to be_empty
    expect(period.reload.payroll_items.find_by!(employee: employee)).to have_attributes(hours_worked: 16, gross_pay: 240)
  end

  %w[final correction adjustment regular bonus].each do |purpose|
    it "lists only explicitly eligible #{purpose} choices within this company" do
      period.update!(status: "draft")
      period.update!(run_purpose: purpose)
      employee.update!(status: "terminated", termination_date: period.start_date - 1.day)
      other = create(:employee, status: "terminated", termination_date: period.start_date - 1.day)
      unconfirmed = create(:employee, company: company)
      unconfirmed.update_columns(intake_exception: { "reason" => "Missing I-9" }, intake_payroll_confirmed_at: nil)
      stub_portal_user(Api::V1::Admin::EmployeesController, staff, company)
      get "/api/v1/admin/employees", params: { eligible_pay_period_id: period.id }
      expect(response).to have_http_status(:ok), response.body
      ids = response.parsed_body.fetch("data").pluck("id")
      expect(ids).not_to include(other.id, unconfirmed.id)
      if %w[final correction adjustment].include?(purpose)
        expect(ids).to include(employee.id)
      else
        expect(ids).not_to include(employee.id)
      end
    end
  end

  it "still requires intake payroll confirmation on an explicit adjustment run" do
    period.update!(status: "draft")
    period.update!(run_purpose: "adjustment")
    employee.update_columns(intake_exception: { "reason" => "Missing I-9" }, intake_payroll_confirmed_at: nil)
    delete url, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(period.pay_period_excluded_employees).to exist(employee_id: employee.id)
  end

  it "allows historically deactivated workers on an explicit adjustment run" do
    period.update!(status: "draft")
    period.update!(run_purpose: "adjustment")
    employee.update!(hire_date: period.start_date - 1.year)
    EmployeeStatusTransitionService.deactivate!(employee: employee, actor: create(:user, company: company, role: "admin"), attributes: { effective_date: period.start_date - 1.day })
    delete url, as: :json
    expect(response).to have_http_status(:ok), response.body
  end

  it "formats removed employee names the same way as the employee profile" do
    employee.update!(middle_name: "Leigh")
    stub_portal_user(Api::V1::Admin::PayPeriodsController, staff, company)
    get "/api/v1/admin/pay_periods/#{period.id}", as: :json
    expect(response.parsed_body.dig("pay_period", "excluded_employees").sole["name"]).to eq(employee.full_name)
  end
end
