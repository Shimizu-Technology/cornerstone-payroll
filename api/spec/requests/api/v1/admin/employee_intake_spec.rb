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
    [ Api::V1::Admin::EmployeeIntakeSettingsController, Api::V1::Admin::EmployeesController, Api::V1::Admin::EmployeeWageRatesController ].each do |controller|
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

  def default_withholding_employee
    enable_window
    post "/api/v1/admin/employees", params: { employee: minimal }
    employee = Employee.find(response.parsed_body.dig("data", "id"))
    EmployeeIntakeExceptionReviewService.call!(employee: employee, actor: admin, attributes: {
      confirm_payroll_setup: true, reason: "Confirmed employer setup", payroll_eligible_from: "2026-01-01", acknowledge_default_withholding: true
    })
    employee.reload
  end

  it "requires an explicit withholding effective date for strict W-2 intake" do
    complete = attributes_for(:employee).except(:ssn_encrypted).merge(ssn: "900-70-1234", ssn_confirmation: "900-70-1234")
    post "/api/v1/admin/employees", params: { employee: complete }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig("details", "w4_effective_on")).to be_present
  end

  it "preserves default withholding on an ordinary full-profile address update" do
    employee = default_withholding_employee
    profile = EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| employee.public_send(attribute) }
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: profile.merge(city: "Hagatna") }
    expect(response).to have_http_status(:ok), response.body
    expect(employee.employee_w4_elections.count).to eq(1)
    expect(employee.reload.intake_payroll_confirmed_at).to be_present
    expect(employee.employee_w4_elections.first.source).to eq("default_withholding")
  end

  it "rejects a fallback replacement without both receipt intent and actual evidence" do
    employee = default_withholding_employee
    profile = EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| employee.public_send(attribute) }
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: profile.merge(filing_status: "married", w4_change_reason: "Changed profile") }
    expect(response).to have_http_status(:unprocessable_entity)
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: profile.merge(w4_election_received: true, w4_change_reason: "Received form") }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(employee.employee_w4_elections.count).to eq(1)
    expect(employee.reload.filing_status).to eq("single")
  end

  it "records a received same-value election only with evidence and reason" do
    employee = default_withholding_employee
    profile = EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| employee.public_send(attribute) }
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: profile.merge(
      w4_election_received: true, w4_source_reference: "Signed W-4 document uploaded", w4_change_reason: "Employer delivered the signed election"
    ) }
    expect(response).to have_http_status(:ok), response.body
    expect(employee.employee_w4_elections.count).to eq(2)
    expect(response.parsed_body.dig("data", "intake_readiness", "missing_fields")).not_to include("withholding_election")
  end

  it "invalidates manager confirmation through wage-rate creation, changes, and deletion" do
    employee = default_withholding_employee
    post "/api/v1/admin/employee_wage_rates", params: { employee_wage_rate: { employee_id: employee.id, label: "Secondary", rate: 25, active: true, is_primary: false } }
    expect(response).to have_http_status(:created), response.body
    rate_id = response.parsed_body.dig("wage_rate", "id")
    expect(employee.reload.intake_payroll_confirmed_at).to be_nil
    [ { rate: 30 }, { active: false }, { is_primary: true } ].each do |changes|
      employee.update_columns(intake_payroll_confirmed_at: Time.current)
      patch "/api/v1/admin/employee_wage_rates/#{rate_id}", params: { employee_wage_rate: changes }
      expect(response).to have_http_status(:ok), response.body
      expect(employee.reload.intake_payroll_confirmed_at).to be_nil
    end
    employee.update_columns(intake_payroll_confirmed_at: Time.current)
    delete "/api/v1/admin/employee_wage_rates/#{rate_id}"
    expect(response).to have_http_status(:ok)
    expect(employee.reload.intake_payroll_confirmed_at).to be_nil
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
