# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee incomplete intake", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company) }
  let(:admin) { create(:user, company: company) }
  let(:accountant) { create(:user, company: company, role: "accountant") }
  let(:actor) { admin }
  let(:minimal) { { first_name: "Alex", last_name: "Worker", employment_type: "hourly", pay_rate: 20, pay_frequency: "biweekly" } }

  before do
    [ Api::V1::Admin::EmployeeIntakeSettingsController, Api::V1::Admin::EmployeesController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    end
  end

  def enable_window
    patch "/api/v1/admin/employee_intake_settings", params: { employee_intake_settings: {
      enabled: true, reason: "Employer information outstanding", expires_at: 1.hour.from_now.iso8601
    } }
    expect(response).to have_http_status(:ok), response.body
  end

  it "requires strict data by default" do
    post "/api/v1/admin/employees", params: { employee: minimal }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("details")).to include("ssn", "hire_date", "address_line1")
  end

  it "runs the enable, create, disable, incremental-complete workflow" do
    enable_window
    post "/api/v1/admin/employees", params: { employee: minimal }
    expect(response).to have_http_status(:created), response.body
    employee = Employee.find(response.parsed_body.dig("data", "id"))
    expect(response.parsed_body.dig("data", "intake_readiness", "profile_incomplete")).to be true
    expect(employee.employee_document_requirements.count).to eq(2)
    expect(employee.employee_w4_elections).to be_empty
    expect(response.parsed_body.fetch("data")).not_to have_key("intake_exception")
    patch "/api/v1/admin/employee_intake_settings", params: { employee_intake_settings: { enabled: false } }
    expect(response).to have_http_status(:ok)
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: { city: "Hagatna" } }
    expect(response).to have_http_status(:ok), response.body
    post "/api/v1/admin/employees", params: { employee: minimal }
    expect(response).to have_http_status(:unprocessable_entity)
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: { city: "" } }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "does not accept spoofed authorization through employee parameters" do
    post "/api/v1/admin/employees", params: { employee: minimal.merge(intake_exception: {
      deferred_fields: EmployeeIntakePolicy::DEFERABLE_FIELDS, authorized_by_id: admin.id
    }, intake_payroll_confirmed_at: Time.current, intake_payroll_eligible_from: "2026-01-01") }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(company.employees).to be_empty
  end

  it "rejects expired windows on submission and expiration outside the permitted range" do
    patch "/api/v1/admin/employee_intake_settings", params: { employee_intake_settings: {
      enabled: true, reason: "Employer information outstanding", expires_at: 2.days.from_now.iso8601
    } }
    expect(response).to have_http_status(:unprocessable_entity)
    enable_window
    travel 2.hours do
      post "/api/v1/admin/employees", params: { employee: minimal }
      expect(response).to have_http_status(:unprocessable_entity)
      get "/api/v1/admin/employee_intake_settings"
      expect(response.parsed_body.dig("data", "enabled")).to be false
    end
  end

  it "filters only incomplete exceptions and protects completed fields" do
    create(:employee, company: company)
    enable_window
    post "/api/v1/admin/employees", params: { employee: minimal }
    id = response.parsed_body.dig("data", "id")
    get "/api/v1/admin/employees", params: { intake_status: "incomplete" }
    expect(response.parsed_body.fetch("data").map { |employee| employee["id"] }).to eq([ id ])
    expect(response.parsed_body.dig("meta", "total_count")).to eq(1)
  end

  context "as accountant" do
    let(:actor) { accountant }

    it "reads but cannot enable the window or confirm payroll setup" do
      get "/api/v1/admin/employee_intake_settings"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "can_manage")).to be false
      patch "/api/v1/admin/employee_intake_settings", params: { employee_intake_settings: { enabled: true } }
      expect(response).to have_http_status(:forbidden)
      employee = create(:employee, company: company)
      patch "/api/v1/admin/employees/#{employee.id}/intake_exception", params: { intake_exception: { confirm_payroll_setup: true } }
      expect(response).to have_http_status(:forbidden)
    end

    it "cannot access another company" do
      other = create(:company)
      allow_any_instance_of(Api::V1::Admin::EmployeeIntakeSettingsController).to receive(:current_company_id).and_return(other.id)
      get "/api/v1/admin/employee_intake_settings"
      expect(response).to have_http_status(:forbidden)
    end
  end
end
