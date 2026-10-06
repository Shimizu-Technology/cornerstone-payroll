# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::EmployeeRetirementYearInputs", type: :request do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:user) { create(:user, company: company, organization: company.organization, role: :manager) }
  let(:path) { "/api/v1/admin/employees/#{employee.id}/retirement_year_inputs" }
  let(:values) do
    { tax_year: 2026, prior_year_wage_status: "verified", prior_year_fica_wages: 160_000,
      prior_year_wage_source: "2025 W-2GU box 3, applicable employer",
      external_traditional_deferrals: 2500, source_reference: "Employee signed statement",
      reason: "Verified annual evidence" }
  end

  before do
    allow_any_instance_of(Api::V1::Admin::EmployeeRetirementYearInputsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::EmployeeRetirementYearInputsController).to receive(:current_user).and_return(user)
  end

  it "appends audited evidence and lists it without accepting tenant or creator overrides" do
    post path, params: { retirement_year_input: values.merge(company_id: create(:company).id, created_by_id: 999) }
    expect(response).to have_http_status(:created)
    input = EmployeeRetirementYearInput.last
    expect(input.company_id).to eq(company.id)
    expect(input.created_by).to eq(user)
    expect(AuditLog.where(action: "employee_retirement_year_inputs#create", record_id: input.id)).to exist
    get path, params: { tax_year: 2026 }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", 0, "created_by_name")).to eq(user.name)
  end

  it "rejects incomplete wage evidence with actionable validation" do
    post path, params: { retirement_year_input: values.except(:prior_year_wage_source) }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("details")).to have_key("prior_year_wage_source")
  end

  it "does not expose another company's employee" do
    other = create(:employee)
    get "/api/v1/admin/employees/#{other.id}/retirement_year_inputs"
    expect(response).to have_http_status(:not_found)
    post "/api/v1/admin/employees/#{other.id}/retirement_year_inputs", params: { retirement_year_input: values }
    expect(response).to have_http_status(:not_found)
  end

  it "denies employee users" do
    user.update!(role: :employee)
    post path, params: { retirement_year_input: values }
    expect(response).to have_http_status(:forbidden)
  end

  it "lets accountants read evidence but prevents changing payroll configuration" do
    user.update!(role: :accountant)
    get path
    expect(response).to have_http_status(:ok)
    expect { post path, params: { retirement_year_input: values } }.not_to change(EmployeeRetirementYearInput, :count)
    expect(response).to have_http_status(:forbidden)
  end

  it "prevents a manager assigned as a test-workspace operator from changing evidence" do
    source = create(:company, organization: company.organization)
    company.update!(payroll_environment: "migration_rehearsal", test_workspace_purpose: "training_replay",
      migration_source_company: source, migration_rehearsal_status: "ready")
    CompanyAssignment.create!(user: user, company: company, workspace_access_level: "operator")
    post path, params: { retirement_year_input: values }
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to include("test workspace access")
    get path
    expect(response).to have_http_status(:ok)
  end
end
