# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Changes to confirm while contact updates are off", type: :request do
  include EmployeeLinkHelpers

  let(:path) { "/api/v1/admin/employee_contact_changes_to_confirm" }
  let(:company) { create(:company, name: "Example Bakery") }
  let(:staff) { create(:user, company: company, role: :admin, clerk_id: "user_changes_to_confirm_staff") }

  def headers
    bearer(staff.clerk_id).merge("X-Company-Id" => company.id.to_s)
  end

  it "answers every action with a feature_off reason instead of a bare not found" do
    get path, headers: headers
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq(
      "error" => "Employee contact and address updates aren't turned on for this company.",
      "code" => "feature_off"
    )

    patch "#{path}/1/confirm", headers: headers
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.fetch("code")).to eq("feature_off")

    patch "#{path}/confirm_all", headers: headers, params: { through_id: 1 }, as: :json
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.fetch("code")).to eq("feature_off")
  end

  it "lists changes once contact and address updates are on" do
    company.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_portals", hours_source: "manual",
      client_portal_enabled: true, employee_portal_enabled: true,
      options: { "employee_portal" => { "features" => { "profile_requests" => true } } }
    )
    activate_employee_app!(company)

    get path, headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("data")).to eq([])
  end
end
