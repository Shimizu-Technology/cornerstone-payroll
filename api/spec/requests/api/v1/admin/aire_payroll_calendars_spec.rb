# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::AirePayrollCalendars", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  # These fixtures describe publication before the October 22 cutoff.
  # Model validations use Time.current as well as the presenter's explicit clock.
  before { travel_to(Time.find_zone!("Pacific/Guam").local(2026, 10, 17, 9)) }
  after { travel_back }

  let(:company) { create(:company, pay_frequency: "semimonthly") }
  let(:admin) { create(:user, company: company, role: "admin") }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let!(:schedule) do
    CompanyPaySchedule.create!(
      company: company,
      frequency: "semimonthly",
      period_rule: "semimonthly",
      pay_date_rule: "semimonthly_15th_and_month_end",
      time_tracking_cutoff_rule: "after_previous_regular_payday",
      time_tracking_cutoff_days: 7,
      payroll_cutoff_at_minutes: 1020,
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
  let!(:previous_regular) do
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: Date.new(2026, 9, 16), end_date: Date.new(2026, 9, 30), pay_date: Date.new(2026, 10, 15))
  end

  let(:pay_period) do
    create(
      :pay_period,
      company: company,
      company_pay_schedule: schedule,
      company_workweek: workweek,
      start_date: Date.new(2026, 10, 1),
      end_date: Date.new(2026, 10, 15),
      pay_date: Date.new(2026, 10, 31)
    )
  end

  before do
    source
    allow_any_instance_of(Api::V1::Admin::AirePayrollCalendarsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::AirePayrollCalendarsController).to receive(:current_company).and_return(company)
    allow_any_instance_of(Api::V1::Admin::AirePayrollCalendarsController).to receive(:current_user).and_return(admin)
    allow(AirePayrollCalendarPublication).to receive(:dispatch_one!)
  end

  it "exposes the pause capability locally and refuses publication before creating evidence" do
    allow(ConnectedPayrollMode).to receive(:enabled?).and_return(false)
    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_calendar"
    expect(response).to have_http_status(:ok)
    state = response.parsed_body.fetch("aire_payroll_calendar")
    expect(state.fetch("connected_payroll")).to include("enabled" => false, "message" => "Connected payroll is paused")
    expect(state).to include("can_publish" => false, "can_retry" => false)
    expect do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_calendar/publish"
    end.not_to change(AirePayrollCalendarPublication, :count)
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Retry-After"]).to eq("60")
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
    expect(response.parsed_body.fetch("error")).to eq("Manager, admin, or Client management access required")
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
  it "lets payroll staff explicitly refresh shared source state and returns both aliases" do
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")
    allow_any_instance_of(Api::V1::Admin::AirePayrollCalendarsController).to receive(:current_user).and_return(accountant)
    calendar = create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: pay_period)
    publication = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, delivery_status: "delivered")
    state = { "external_pay_period_id" => calendar.external_pay_period_id, "publication_id" => publication.publication_id,
      "schedule_version" => 1, "next_scheduled_cutoff_at" => nil }
    allow_any_instance_of(TimeTracking::Client).to receive(:payroll_calendar_period).and_return(state)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_calendar/refresh"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("aire_payroll_calendar")).to include("next_scheduled_cutoff_at" => nil,
      "next_scheduled_cutoff_status" => "available")
    expect(response.parsed_body["time_tracking_calendar"]).to eq(response.parsed_body["aire_payroll_calendar"])
    expect(source.reload.payroll_calendar_source_state["status"]).to eq("available")
  end

  it "keeps failed refresh distinguishable from no upcoming scheduled cutoff" do
    create(:aire_payroll_calendar_publication, delivery_status: "delivered",
      aire_payroll_calendar_period: create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: pay_period))
    allow_any_instance_of(TimeTracking::Client).to receive(:payroll_calendar_period).and_raise(TimeTracking::Client::Error, "Offline")
    post "/api/v1/admin/pay_periods/#{pay_period.id}/time_tracking_calendar/refresh"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("aire_payroll_calendar")).to include("next_scheduled_cutoff_at" => nil,
      "next_scheduled_cutoff_status" => "unavailable")
  end

  it "does not refresh another client's source" do
    other_period = create(:pay_period)
    expect_any_instance_of(TimeTracking::Client).not_to receive(:payroll_calendar_period)
    post "/api/v1/admin/pay_periods/#{other_period.id}/aire_payroll_calendar/refresh"
    expect(response).to have_http_status(:not_found)
  end
end
