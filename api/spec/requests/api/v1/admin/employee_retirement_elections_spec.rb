# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::EmployeeRetirementElections", type: :request do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:user) { create(:user, company: company, organization: company.organization, role: :accountant) }
  let(:params) do
    {
      retirement_election: {
        effective_on: "2026-09-20",
        plan_name: "MoSa 401(k)",
        eligible: true,
        participating: true,
        traditional_contribution_type: "fixed",
        traditional_amount: 450,
        traditional_rate: 0,
        roth_contribution_type: "percentage",
        roth_rate: 0.03,
        roth_amount: 0,
        eligible_compensation: "gross_excluding_tips",
        catch_up_enabled: true,
        limit_priority: "traditional_first",
        employer_match_mode: "employee_deferral_percentage",
        employer_match_rate: 1,
        employer_match_deferral_cap_rate: 0.04,
        employer_match_ytd_before_system: 300,
        employer_match_destination: "traditional",
        true_up_policy: "year_to_date",
        reason: "Signed election received"
      }
    }
  end

  before do
    allow_any_instance_of(Api::V1::Admin::EmployeeRetirementElectionsController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::EmployeeRetirementElectionsController)
      .to receive(:current_user).and_return(user)
  end

  it "creates and returns a dated election" do
    post "/api/v1/admin/employees/#{employee.id}/retirement_elections", params: params

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("data", "plan_name")).to eq("MoSa 401(k)")
    expect(response.parsed_body.dig("data", "traditional_amount").to_f).to eq(450)
    expect(response.parsed_body.dig("data", "created_by_name")).to eq(user.name)
  end

  it "lists the immutable election history newest first" do
    first = params.deep_dup
    first[:retirement_election][:effective_on] = "2026-09-01"
    post "/api/v1/admin/employees/#{employee.id}/retirement_elections", params: first
    second = params.deep_dup
    second[:retirement_election][:effective_on] = "2026-09-20"
    second[:retirement_election][:traditional_amount] = 500
    second[:retirement_election][:reason] = "Employee increased contribution"
    post "/api/v1/admin/employees/#{employee.id}/retirement_elections", params: second

    get "/api/v1/admin/employees/#{employee.id}/retirement_elections"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").map { |entry| entry["traditional_amount"].to_f }).to eq([ 500, 450 ])
  end

  it "does not expose another company's employee" do
    other = create(:employee)
    post "/api/v1/admin/employees/#{other.id}/retirement_elections", params: params

    expect(response).to have_http_status(:not_found)
  end
end
