# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::AireEmployeeCandidates", type: :request do
  let(:company) { create(:company) }
  let(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:client) { instance_double(TimeTracking::Client) }
  let(:source_uuid) { SecureRandom.uuid }

  before do
    allow_any_instance_of(Api::V1::Admin::AireEmployeeCandidatesController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::AireEmployeeCandidatesController).to receive(:current_company).and_return(company)
    allow_any_instance_of(Api::V1::Admin::AireEmployeeCandidatesController).to receive(:current_user).and_return(admin)
    allow(TimeTracking::Client).to receive(:new).and_return(client)
  end

  def roster
    {
      "employees" => [
        {
          "id" => "91", "payroll_integration_id" => source_uuid,
          "first_name" => "Rei", "last_name" => "Example", "full_name" => "Rei Example",
          "email" => "rei@example.com", "active" => true, "time_tracking_enabled" => true
        }
      ],
      "pagination" => { "current_page" => 1, "per_page" => 100, "total_count" => 1, "total_pages" => 1, "truncated" => false }
    }
  end

  it "shows AIRE people without a published period and flags a possible inactive payroll profile" do
    source
    existing = create(:employee, company: company, department: create(:department, company: company),
                               first_name: "Rei", last_name: "Example", status: "terminated")
    allow(client).to receive(:payroll_cockpit_employees).and_return(roster)

    get "/api/v1/admin/aire_employee_candidates"

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(client).to have_received(:payroll_cockpit_employees).with(page: 1, per_page: 100, active: true, employee_id: nil)
    person = response.parsed_body.fetch("employees").first
    expect(person.dig("cornerstone", "status")).to eq("unmapped")
    expect(person.fetch("possible_payroll_matches")).to include(
      "id" => existing.id, "name" => existing.full_name, "status" => "terminated"
    )
    expect(company.employees.count).to eq(1)
  end

  it "upgrades an existing numeric-only link with the live permanent identity" do
    source
    existing = create(:employee, company: company, department: create(:department, company: company))
    mapping = TimeTrackingEmployeeMapping.create!(
      company: company, time_tracking_source: source, employee: existing, source_user_id: "91"
    )
    allow(client).to receive(:payroll_cockpit_employees).and_return(roster)

    post "/api/v1/admin/aire_employee_candidates/link", params: { source_user_id: "91", employee_id: existing.id }

    expect(response).to have_http_status(:ok)
    expect(mapping.reload.source_user_uuid).to eq(source_uuid)
    expect(client).to have_received(:payroll_cockpit_employees).with(page: 1, per_page: 1, employee_id: "91")
  end

  it "leaves payroll unchanged when AIRE has not been connected" do
    get "/api/v1/admin/aire_employee_candidates"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("connected" => false, "employees" => [])
    expect(TimeTracking::Client).not_to have_received(:new)
  end
end
