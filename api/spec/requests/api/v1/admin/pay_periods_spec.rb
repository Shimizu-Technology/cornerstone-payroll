# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayPeriods", type: :request do
  let!(:company) { Company.create!(name: "Test Company") }
  let!(:department) { Department.create!(name: "Engineering", company: company) }
  let!(:employee) do
    Employee.create!(
      company: company,
      department: department,
      first_name: "John",
      last_name: "Doe",
      email: "john@example.com",
      employment_type: "hourly",
      pay_rate: 15.00,
      pay_frequency: "biweekly",
      filing_status: "single",
      allowances: 1,
      status: "active",
      hire_date: Date.today - 1.year
    )
  end
  let!(:pay_period) do
    PayPeriod.create!(
      company: company,
      start_date: Date.today - 14.days,
      end_date: Date.today,
      pay_date: Date.today + 3.days,
      status: "draft"
    )
  end

  before do
    # Stub company_id for tests
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(1)
  end

  describe "GET /api/v1/admin/pay_periods" do
    it "returns all pay periods for the company" do
      get "/api/v1/admin/pay_periods"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["pay_periods"].length).to eq(1)
      expect(json["pay_periods"][0]["status"]).to eq("draft")
    end

    it "filters by status" do
      PayPeriod.create!(company: company, start_date: Date.today - 28.days, end_date: Date.today - 14.days, pay_date: Date.today - 11.days, status: "committed")

      get "/api/v1/admin/pay_periods", params: { status: "draft" }

      json = JSON.parse(response.body)
      expect(json["pay_periods"].length).to eq(1)
      expect(json["pay_periods"][0]["status"]).to eq("draft")
    end
  end

  describe "GET /api/v1/admin/pay_periods/:id" do
    it "returns the pay period with payroll items" do
      get "/api/v1/admin/pay_periods/#{pay_period.id}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["pay_period"]["id"]).to eq(pay_period.id)
      expect(json["pay_period"]).to have_key("payroll_items")
    end
  end

  describe "POST /api/v1/admin/pay_periods" do
    it "creates a new pay period" do
      params = {
        pay_period: {
          start_date: Date.today,
          end_date: Date.today + 14.days,
          pay_date: Date.today + 17.days
        }
      }

      expect {
        post "/api/v1/admin/pay_periods", params: params
      }.to change(PayPeriod, :count).by(1)

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["pay_period"]["status"]).to eq("draft")
    end

    it "returns errors for invalid data" do
      params = {
        pay_period: {
          start_date: Date.today,
          end_date: Date.today - 1.day, # End before start
          pay_date: Date.today + 17.days
        }
      }

      post "/api/v1/admin/pay_periods", params: params

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /api/v1/admin/pay_periods/:id" do
    it "updates a draft pay period" do
      patch "/api/v1/admin/pay_periods/#{pay_period.id}", params: {
        pay_period: { notes: "Updated notes" }
      }

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload.notes).to eq("Updated notes")
    end

    it "cannot update a committed pay period" do
      pay_period.update!(status: "committed")

      patch "/api/v1/admin/pay_periods/#{pay_period.id}", params: {
        pay_period: { notes: "Try to update" }
      }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /api/v1/admin/pay_periods/:id" do
    it "deletes a draft pay period" do
      expect {
        delete "/api/v1/admin/pay_periods/#{pay_period.id}"
      }.to change(PayPeriod, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "cannot delete a committed pay period" do
      pay_period.update!(status: "committed")

      delete "/api/v1/admin/pay_periods/#{pay_period.id}"

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/run_payroll" do
    before do
      # Create tax tables for calculations (use find_or_create to avoid uniqueness conflicts)
      TaxTable.find_or_create_by!(
        tax_year: Date.today.year,
        filing_status: "single",
        pay_frequency: "biweekly"
      ) do |t|
        t.ss_rate = 0.062
        t.ss_wage_base = 184500.00
        t.medicare_rate = 0.0145
        t.allowance_amount = 192.31
        t.bracket_data = [
          { min_income: 0, max_income: 476.92, rate: 0.10, base_tax: 0, threshold: 0 },
          { min_income: 476.93, max_income: 1938.46, rate: 0.12, base_tax: 47.69, threshold: 476.93 },
          { min_income: 1938.47, max_income: 999999999, rate: 0.22, base_tax: 223.07, threshold: 1938.47 }
        ]
      end
    end

    it "calculates payroll for all active employees" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["results"]["success"].length).to eq(1)
      expect(json["pay_period"]["status"]).to eq("calculated")
      expect(pay_period.reload.payroll_items.count).to eq(1)
    end

    it "calculates with custom hours" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: {
        hours: {
          employee.id.to_s => { regular: 80, overtime: 10 }
        }
      }

      expect(response).to have_http_status(:ok)
      item = pay_period.reload.payroll_items.first
      expect(item.hours_worked).to eq(80)
      expect(item.overtime_hours).to eq(10)
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/approve" do
    it "approves a calculated pay period" do
      pay_period.update!(status: "calculated")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/approve"

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload.status).to eq("approved")
    end

    it "cannot approve a draft pay period" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/approve"

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/commit" do
    before do
      pay_period.update!(status: "approved")
      PayrollItem.create!(
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 15.00,
        hours_worked: 80,
        gross_pay: 1200.00,
        withholding_tax: 100.00,
        social_security_tax: 74.40,
        medicare_tax: 17.40,
        net_pay: 1008.20
      )
    end

    it "commits an approved pay period and updates YTD" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload.status).to eq("committed")
      expect(pay_period.committed_at).to be_present

      # Check YTD was updated
      ytd = EmployeeYtdTotal.find_by(employee: employee, year: pay_period.pay_date.year)
      expect(ytd).to be_present
      expect(ytd.gross_pay).to eq(1200.00)
    end
  end
end
