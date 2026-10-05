# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee hours evidence", type: :request do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:actor) { create(:user, company: company, role: "accountant") }

  before do
    allow_any_instance_of(Api::V1::Admin::EmployeeHoursEvidenceController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::EmployeeHoursEvidenceController).to receive(:current_user).and_return(actor)
  end

  it "allows payroll staff to review an unlinked employee without asserting unpaid work" do
    get "/api/v1/admin/employees/#{employee.id}/hours_evidence"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("status" => "not_linked", "sources" => [])
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "cannot view a different company's employee" do
    other = create(:employee)
    get "/api/v1/admin/employees/#{other.id}/hours_evidence"
    expect(response).to have_http_status(:not_found)
  end

  it "cannot select another company's source, even with an overlapping source employee ID" do
    source = create(:time_tracking_source, active: false)
    own_source = create(:time_tracking_source, company: company, active: false)
    mapping = TimeTrackingEmployeeMapping.create!(company: company, employee: employee, time_tracking_source: own_source, source_user_id: "42")
    # Exercise a corrupt historical association without bypassing current write validation.
    mapping.update_columns(time_tracking_source_id: source.id)
    get "/api/v1/admin/employees/#{employee.id}/hours_evidence", params: { source_id: source.id }
    expect(response).to have_http_status(:not_found)
  end

  it "rejects invalid date filters instead of silently displaying all time" do
    get "/api/v1/admin/employees/#{employee.id}/hours_evidence", params: { start_date: "2026-02-30" }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "does not admit a client user to staff employee evidence" do
    actor.update!(role: "client")
    get "/api/v1/admin/employees/#{employee.id}/hours_evidence"
    expect(response).to have_http_status(:forbidden)
  end
end
