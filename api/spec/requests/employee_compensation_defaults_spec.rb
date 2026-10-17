# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Current compensation defaults", type: :request do
  let!(:company) { create(:company, pay_frequency: "semimonthly") }
  let!(:actor) { create(:user, company: company, role: "admin") }

  before do
    load Rails.root.join("db/seeds/tax_configs.rb")
    [ Api::V1::Admin::EmployeesController, Api::V1::Admin::PayPeriodsController,
      Api::V1::Admin::PayrollItemsController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
    end
  end

  def headers
    { "X-Company-Id" => company.id.to_s }
  end

  def employee_attributes
    attributes_for(:employee).except(:ssn_encrypted).merge(ssn: "900701234", ssn_confirmation: "900701234",
      w4_effective_on: "2026-01-01")
  end

  it "defaults omitted employee frequency to the selected company and preserves explicit overrides" do
    post "/api/v1/admin/employees", headers: headers, params: { employee: employee_attributes.except(:pay_frequency) }
    expect(response).to have_http_status(:created), response.body
    expect(company.employees.sole.pay_frequency).to eq("semimonthly")
    post "/api/v1/admin/employees", headers: headers, params: { employee: employee_attributes.merge(
      ssn: "900701235", ssn_confirmation: "900701235", pay_frequency: "weekly") }
    expect(response).to have_http_status(:created), response.body
    expect(company.employees.order(:id).last.pay_frequency).to eq("weekly")
  end

  %w[biweekly semimonthly].zip([ 2000.to_d, 2166.67.to_d ]).each do |frequency, expected|
    it "calculates #{frequency} salary after hourly conversion without losing retained hourly definitions" do
      employee = create(:employee, company: company, pay_rate: 25, pay_frequency: frequency)
      rate = create(:employee_wage_rate, employee: employee, rate: 25, is_primary: true)
      employee.update!(employment_type: "salary", salary_type: "annual", pay_rate: 52_000)
      period = create(:pay_period, company: company, status: "draft", start_date: "2026-09-13", end_date: "2026-09-26", pay_date: "2026-10-02")
      post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", headers: headers,
        params: { employee_ids: [ employee.id ] }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("results", "errors")).to be_blank, response.body
      expect(period.payroll_items).to be_present, response.body
      item = period.payroll_items.sole
      expect(item.pay_rate).to eq(52_000.to_d)
      expect(item.gross_pay).to eq(expected)
      expect(rate.reload.rate).to eq(25.to_d)
      post "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}/recalculate", headers: headers
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.gross_pay).to eq(expected)
      expect(item.wage_rate_hours).to eq([])
    end
  end

  it "returns a flat contractor fee without reusing its retained hourly rate" do
    employee = create(:employee, :contractor, company: company, contractor_pay_type: "hourly", pay_rate: 25)
    rate = create(:employee_wage_rate, employee: employee, rate: 25, is_primary: true)
    employee.update!(contractor_pay_type: "flat_fee", pay_rate: 500)
    expect(employee.default_payroll_rate).to eq(500.to_d)
    expect(rate.reload.rate).to eq(25.to_d)
  end

  it "refreshes the current basis of an editable hourly row after conversion to salary" do
    employee = create(:employee, company: company, pay_rate: 25, pay_frequency: "biweekly")
    rate = create(:employee_wage_rate, employee: employee, rate: 25, is_primary: true)
    period = create(:pay_period, company: company, status: "calculated", start_date: "2026-09-13", end_date: "2026-09-26", pay_date: "2026-10-02")
    item = create(:payroll_item, company: company, employee: employee, pay_period: period, employment_type: "hourly",
      pay_rate: 25, hours_worked: 80, wage_rate_hours: [ { "employee_wage_rate_id" => rate.id, "label" => rate.label,
        "rate" => 25, "regular_hours" => 80, "overtime_hours" => 0, "is_primary" => true, "active" => true } ])
    employee.update!(employment_type: "salary", salary_type: "annual", pay_rate: 52_000)
    post "/api/v1/admin/pay_periods/#{period.id}/refresh_setup", headers: headers,
      params: { includes_base_salary: true, includes_recurring_items: true }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("results", "errors")).to be_blank, response.body
    expect(item.reload.employment_type).to eq("salary")
    expect(item.pay_rate).to eq(52_000.to_d)
    expect(item.gross_pay).to eq(2000.to_d)
    expect(rate.reload.rate).to eq(25.to_d)
  end

  it "rejects stale hourly worksheet input after the worker changes to salary without saving a wrong annual rate" do
    employee = create(:employee, :salary, company: company, pay_rate: 52_000)
    rate = create(:employee_wage_rate, employee: employee, rate: 25, is_primary: true)
    period = create(:pay_period, company: company, start_date: "2026-09-13", end_date: "2026-09-26", pay_date: "2026-10-02")
    post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", headers: headers, params: {
      employee_ids: [ employee.id ], hours: { employee.id.to_s => { wage_rates: [ {
        employee_wage_rate_id: rate.id, label: rate.label, rate: 25, regular_hours: 80, overtime_hours: 0, is_primary: true, active: true
      } ] } }
    }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("results", "success")).to be_empty
    expect(response.parsed_body.dig("results", "errors").sole.fetch("error")).to include("Reload the worksheet", "not applied")
    expect(period.payroll_items).to be_empty
    expect(employee.reload.pay_rate).to eq(52_000.to_d)
  end
end
