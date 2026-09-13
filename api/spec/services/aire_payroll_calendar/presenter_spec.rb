# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendar::Presenter do
  let(:company) { create(:company, pay_frequency: "semimonthly") }
  let(:actor) { create(:user, company: company) }
  let!(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let!(:schedule) do
    CompanyPaySchedule.create!(
      company: company,
      frequency: "semimonthly",
      period_rule: "semimonthly",
      pay_date_rule: "manual",
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: actor,
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
      confirmed_by: actor,
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

  it "shows a missed unpublished cutoff as unavailable instead of offering a broken publish action" do
    state = described_class.call(
      pay_period,
      now: Time.find_zone!("Pacific/Guam").local(2026, 10, 18, 17)
    )

    expect(state).to include(
      eligible: false,
      can_publish: false,
      cutoff_state: "cutoff_due"
    )
    expect(state.fetch(:eligibility_error)).to include("passed before it was published")
  end

  it "does not offer a schedule revision after the delivered cutoff has passed" do
    calendar_period = create(
      :aire_payroll_calendar_period,
      company: company,
      time_tracking_source: source,
      pay_period: pay_period
    )
    create(
      :aire_payroll_calendar_publication,
      aire_payroll_calendar_period: calendar_period,
      delivery_status: "delivered",
      delivered_at: Time.find_zone!("Pacific/Guam").local(2026, 10, 17, 17)
    )
    pay_period.update!(pay_date: Date.new(2026, 11, 5))

    state = described_class.call(
      pay_period,
      now: Time.find_zone!("Pacific/Guam").local(2026, 10, 20, 9)
    )

    expect(state).to include(
      eligible: true,
      needs_revision: true,
      can_publish: false,
      cutoff_state: "schedule_changed"
    )
  end
end
