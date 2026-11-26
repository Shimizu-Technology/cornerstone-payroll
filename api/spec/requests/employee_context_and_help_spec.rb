# frozen_string_literal: true

require "rails_helper"

# GET /employee/context and /employee/help with real Clerk token verification
# and the RLS guard in raise mode.
RSpec.describe "Employee context and help", type: :request do
  include EmployeeLinkHelpers

  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, name: "Alpha Grill") }
  let(:employee) { create(:employee, company: company, first_name: "  Jordan ", last_name: "Reyes", email: nil) }
  let(:worker) { create(:user, role: :portal_employee, company: company, clerk_id: "user_jordan") }
  let!(:link) { EmployeeAccountLink.create!(user: worker, company: company, employee: employee, status: "active") }
  let(:today) { PayrollBusinessClock.today }

  before do
    company.client_operating_profiles.create!(
      effective_on: today, version: 1, offering: "payroll_service", hours_source: "manual", employee_portal_enabled: true,
      options: { "employee_portal" => { "features" => { "stubs" => true, "profile_requests" => false } } }
    )
    activate_employee_app!(company)
  end

  def headers_for(target_link = link)
    bearer("user_jordan").merge("X-Employee-Link-Id" => target_link.id.to_s)
  end

  def context
    get "/api/v1/employee/context", headers: headers_for
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def unconfirmed_schedule
    CompanyPaySchedule.create!(company: company, frequency: "biweekly", period_rule: "manual", pay_date_rule: "manual",
      timezone: "Pacific/Guam", effective_on: today - 30)
  end

  def period_on(pay_date, status: "draft", schedule: nil, **attributes)
    period = create(:pay_period, company: company, start_date: pay_date - 13, end_date: pay_date - 6, pay_date: pay_date,
      status: status, committed_at: (Time.current if status == "committed"), **attributes)
    period.update_columns(company_pay_schedule_id: schedule.id) if schedule
    period
  end

  describe "GET /api/v1/employee/context" do
    it "returns the employee's first name, link status, switches and no unsettled payday" do
      expect(context).to eq(
        "first_name" => "Jordan", "status" => "active", "former_access_until" => nil, "next_payday" => nil,
        "w2_delivery" => nil, "demo" => false, "features" => { "stubs" => true, "tax_forms" => false, "profile_requests" => false, "delivery_consent" => false }
      )
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "gives the next payday from the next committed regular run" do
      period_on(today - 3, status: "committed")
      period_on(today + 4, status: "committed", run_purpose: "bonus")
      period_on(today + 9, status: "committed")
      period_on(today + 23, status: "committed")

      expect(context.fetch("next_payday")).to eq((today + 9).iso8601)
    end

    it "gives a run that isn't committed yet only when it was created on a confirmed schedule" do
      unconfirmed = period_on(today + 9, schedule: unconfirmed_schedule)
      period_on(today + 23, status: "committed")
      # The next run's date isn't settled, so nothing shows rather than a later date.
      expect(context.fetch("next_payday")).to be_nil

      # Confirmed, but a manual-dates schedule's draft date is still tentative.
      schedule = CompanyPaySchedule.find(unconfirmed.company_pay_schedule_id)
      schedule.update!(source: "operator_confirmed",
        confirmation_status: "confirmed", confirmed_by: create(:user, role: :admin, company: company),
        confirmed_at: Time.current, notes: "Confirmed biweekly calendar")
      expect(context.fetch("next_payday")).to be_nil

      schedule.update!(frequency: "semimonthly", period_rule: "semimonthly", pay_date_rule: "semimonthly_15th_and_month_end")
      expect(context.fetch("next_payday")).to eq((today + 9).iso8601)
    end

    it "gives the date of a committed correction run that replaced a voided upcoming run" do
      voided = period_on(today + 9, status: "committed", correction_status: "voided")
      period_on(today + 9, status: "committed", correction_status: "correction", source_pay_period_id: voided.id)
      period_on(today + 23, status: "committed")

      expect(context.fetch("next_payday")).to eq((today + 9).iso8601)
    end

    it "never gives a payday from a voided, practice or other company's run" do
      period_on(today + 2, status: "committed", correction_status: "voided")
      other = create(:company, organization: organization)
      create(:pay_period, :committed, company: other, start_date: today - 10, end_date: today - 3, pay_date: today + 3)

      expect(context.fetch("next_payday")).to be_nil
    end

    it "gives a former employee the last access day and never a payday" do
      period_on(today + 9, status: "committed")
      link.update!(status: "former", former_at: Time.current,
        former_access_until: (today + 700).in_time_zone(PayrollBusinessClock::TIME_ZONE).end_of_day)

      expect(context).to include("status" => "former", "former_access_until" => (today + 700).iso8601, "next_payday" => nil)
    end

    it "is a bare 404 for another person's link or a company with the app off" do
      other_user = create(:user, role: :portal_employee, company: company, clerk_id: "user_other")
      others = EmployeeAccountLink.create!(user: other_user, company: company, employee: create(:employee, company: company),
        status: "active")
      get "/api/v1/employee/context", headers: headers_for(others)
      expect([ response.status, response.body ]).to eq([ 404, "" ])

      company.client_operating_profiles.sole.update_columns(employee_portal_enabled: false)
      get "/api/v1/employee/context", headers: headers_for
      expect([ response.status, response.body ]).to eq([ 404, "" ])
    end
  end

  describe "GET /api/v1/employee/help" do
    it "returns only this company's help contacts, in order" do
      CompanyHelpContact.create!(company: company, position: 2, name: "Sam Cruz", role: "Shift lead", email: "lead@example.com")
      CompanyHelpContact.create!(company: company, position: 1, name: "Alex Santos", role: "Manager", phone: "671-555-0100",
        text_ok: true)
      other = create(:company, organization: organization)
      CompanyHelpContact.create!(company: other, position: 1, name: "Other Manager", phone: "671-555-0199")

      get "/api/v1/employee/help", headers: headers_for
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.parsed_body).to eq("help_contacts" => [
        { "name" => "Alex Santos", "role" => "Manager", "phone" => "671-555-0100", "email" => nil, "text_ok" => true },
        { "name" => "Sam Cruz", "role" => "Shift lead", "phone" => nil, "email" => "lead@example.com", "text_ok" => false }
      ])
    end

    it "returns an empty list before the client sets contacts, and a bare 404 without a link" do
      get "/api/v1/employee/help", headers: headers_for
      expect(response.parsed_body).to eq("help_contacts" => [])

      get "/api/v1/employee/help", headers: bearer("user_jordan")
      expect([ response.status, response.body ]).to eq([ 404, "" ])
    end
  end
end
