# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::EmployeeWorkProfiles", type: :request do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, :salary, company: company, department: nil, hire_date: Date.new(2026, 1, 1)) }
  let(:manager) { create(:user, company: company, organization: company.organization, role: :manager) }
  let(:accountant) { create(:user, company: company, organization: company.organization, role: :accountant) }
  let(:current_user) { manager }

  before do
    allow_any_instance_of(Api::V1::Admin::EmployeeWorkProfilesController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::EmployeeWorkProfilesController)
      .to receive(:current_user).and_return(current_user)
  end

  describe "POST /api/v1/admin/employees/:employee_id/work_profiles" do
    let(:params) do
      {
        work_profile: {
          effective_on: "2026-01-01",
          pay_basis: "salary",
          overtime_status: "exempt",
          exemption_category: "administrative",
          exemption_reason: "Employer confirmed the applicable duties and salary basis tests.",
          standard_weekly_hours: 40,
          timekeeping_mode: "schedule_with_exceptions",
          source: "operator_confirmed",
          notes: "Confirmed from the employer's written policy.",
          daily_schedule: {
            sunday: 0, monday: 8, tuesday: 8, wednesday: 8,
            thursday: 8, friday: 8, saturday: 0
          }
        }
      }
    end

    it "creates an effective-dated profile for a manager" do
      expect {
        post "/api/v1/admin/employees/#{employee.id}/work_profiles", params: params
      }.to change(EmployeeWorkProfile, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "confirmed_by_name")).to eq(manager.name)
      expect(response.parsed_body.dig("data", "notes")).to eq("Confirmed from the employer's written policy.")
    end

    context "when signed in as an accountant" do
      let(:current_user) { accountant }

      it "does not permit changing salary work rules" do
        expect {
          post "/api/v1/admin/employees/#{employee.id}/work_profiles", params: params
        }.not_to change(EmployeeWorkProfile, :count)

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET /api/v1/admin/employees/:employee_id/work_profiles" do
    before do
      create(
        :employee_work_profile,
        employee: employee,
        confirmed_by: manager,
        notes: "Restricted employer confirmation detail"
      )
    end

    it "returns restricted setup notes to managers" do
      get "/api/v1/admin/employees/#{employee.id}/work_profiles"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", 0, "notes")).to eq("Restricted employer confirmation detail")
    end

    context "when signed in as an accountant" do
      let(:current_user) { accountant }

      it "redacts restricted setup notes" do
        get "/api/v1/admin/employees/#{employee.id}/work_profiles"

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("data", 0)).not_to have_key("notes")
      end
    end
  end
end
