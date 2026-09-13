# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::AirePayrollCalendars", type: :request do
  let(:company) { create(:company, pay_frequency: "semimonthly") }
  let(:admin) { create(:user, company: company, role: "admin") }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let!(:schedule) do
    CompanyPaySchedule.create!(
      company: company,
      frequency: "semimonthly",
      period_rule: "semimonthly",
      pay_date_rule: "manual",
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: admin,
      confirmed_at: Time.current,
      effective_on: Date.new(2026, 1, 1),
      notes: "Confirmed semimonthly calendar"
    )
  end
  let!(:workweek) do
    CompanyWorkweek.create!(
      company: company,
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: admin,
      confirmed_at: Time.current,
      effective_on: Date.new(2026, 1, 1),
      notes: "Confirmed Sunday workweek"
    )
  end
  let(:pay_period) do
    create(
      :pay_period,
      company: company,
      company_pay_schedule: schedule,
      company_workweek: workweek,
      start_date: Date.new(2026, 10, 1),
      end_date: Date.new(2026, 10, 15),
      pay_date: Date.new(2026, 10, 25)
    )
  end

  before do
    source
    allow_any_instance_of(Api::V1::Admin::AirePayrollCalendarsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::AirePayrollCalendarsController).to receive(:current_company).and_return(company)
    allow_any_instance_of(Api::V1::Admin::AirePayrollCalendarsController).to receive(:current_user).and_return(admin)
    allow(AirePayrollCalendarPublication).to receive(:dispatch_one!)
  end

  it "shows eligibility and publishes the active client's pay period" do
    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_calendar"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("aire_payroll_calendar", "cutoff_state")).to eq("unpublished")

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_calendar/publish"

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("aire_payroll_calendar", "publication")).to include(
      "schedule_version" => 1,
      "delivery_status" => "pending"
    )
  end

  it "does not expose another client's pay period" do
    other_period = create(:pay_period)

    get "/api/v1/admin/pay_periods/#{other_period.id}/aire_payroll_calendar"

    expect(response).to have_http_status(:not_found)
  end

  it "lets accountants view calendar state but not publish it" do
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")
    allow_any_instance_of(Api::V1::Admin::AirePayrollCalendarsController).to receive(:current_user).and_return(accountant)

    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_calendar"
    expect(response).to have_http_status(:ok)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_calendar/publish"
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Manager or admin access required")
  end

  it "queues the requested failed publication directly when delivery is retried" do
    calendar = create(
      :aire_payroll_calendar_period,
      company: company,
      time_tracking_source: source,
      pay_period: pay_period
    )
    publication = create(
      :aire_payroll_calendar_publication,
      aire_payroll_calendar_period: calendar,
      delivery_status: "failed",
      next_delivery_attempt_at: 1.hour.from_now
    )

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_calendar/retry_delivery"

    expect(response).to have_http_status(:ok)
    expect(AirePayrollCalendarPublication).to have_received(:dispatch_one!).with(publication.id)
    expect(publication.reload.next_delivery_attempt_at).to be_within(2.seconds).of(Time.current)
  end
end
