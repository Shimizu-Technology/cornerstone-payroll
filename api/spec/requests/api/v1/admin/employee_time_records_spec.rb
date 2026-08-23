# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::EmployeeTimeRecords", type: :request do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, department: nil) }
  let(:manager) { create(:user, company: company, organization: company.organization, role: :manager) }
  let(:work_date) { Date.new(2026, 8, 17) }
  let(:params) do
    {
      time_record: {
        work_date: work_date.iso8601,
        scheduled_hours: 8,
        actual_worked_hours: 8
      }
    }
  end

  before do
    allow_any_instance_of(Api::V1::Admin::EmployeeTimeRecordsController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::EmployeeTimeRecordsController)
      .to receive(:current_user).and_return(manager)
  end

  it "records the configured workweek bucket only after employer confirmation" do
    workweek = create_workweek!(starts_on_weekday: 1)

    post "/api/v1/admin/employees/#{employee.id}/time_records", params: params

    expect(response).to have_http_status(:created)
    expect(employee.daily_time_records.last).to have_attributes(
      work_date: work_date,
      workweek_started_on: Date.new(2026, 8, 17)
    )
    expect(workweek).to be_confirmed
  end

  it "rejects an unconfirmed legacy workweek" do
    create_workweek!(confirmed: false)

    expect do
      post "/api/v1/admin/employees/#{employee.id}/time_records", params: params
    end.not_to change(DailyTimeRecord, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to match(/Confirm the company's legal workweek/)
  end

  it "rejects a legacy non-midnight workweek" do
    workweek = create_workweek!
    workweek.update_column(:starts_at_minutes, 480)

    expect do
      post "/api/v1/admin/employees/#{employee.id}/time_records", params: params
    end.not_to change(DailyTimeRecord, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to match(/starts at midnight/)
  end

  def create_workweek!(starts_on_weekday: 0, confirmed: true)
    CompanyWorkweek.create!(
      company: company,
      starts_on_weekday: starts_on_weekday,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: confirmed ? "operator_confirmed" : "legacy_system_default",
      confirmation_status: confirmed ? "confirmed" : "needs_confirmation",
      confirmed_by: confirmed ? manager : nil,
      confirmed_at: confirmed ? Time.current : nil,
      notes: confirmed ? "Employer-confirmed legal workweek" : nil,
      effective_on: work_date - 1.year
    )
  end
end
