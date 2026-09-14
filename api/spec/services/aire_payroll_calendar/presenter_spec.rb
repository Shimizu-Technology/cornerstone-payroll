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
    expect(state.fetch(:eligibility_code)).to eq("cutoff_passed")
  end

  it "explains when confirmed AIRE setup starts after an older pay period" do
    schedule.update!(effective_on: Date.new(2026, 9, 16))
    legacy_schedule = CompanyPaySchedule.create!(
      company: company,
      frequency: "semimonthly",
      period_rule: "manual",
      pay_date_rule: "manual",
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1),
      ends_on: Date.new(2026, 9, 15)
    )
    pay_period.update_columns(
      start_date: Date.new(2026, 8, 16),
      end_date: Date.new(2026, 8, 31),
      pay_date: Date.new(2026, 9, 15),
      company_pay_schedule_id: legacy_schedule.id
    )

    state = described_class.call(pay_period, now: Time.find_zone!("Pacific/Guam").local(2026, 9, 1, 9))

    expect(state).to include(
      eligible: false,
      can_publish: false,
      eligibility_code: "pay_schedule_not_effective"
    )
    expect(state.fetch(:eligibility_error)).to include("takes effect on September 16, 2026")
  end

  it "rejects an attached schedule that no longer covers the pay period" do
    schedule.update!(effective_on: Date.new(2026, 10, 16))

    state = described_class.call(pay_period, now: Time.find_zone!("Pacific/Guam").local(2026, 10, 1, 9))

    expect(state).to include(
      eligible: false,
      can_publish: false,
      eligibility_code: "pay_schedule_not_effective"
    )
    expect(state.fetch(:eligibility_error)).to include("takes effect on October 16, 2026")
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

  it "keeps the calendar period tied to its original source when that source is inactive" do
    source.update!(active: false)
    replacement = create(:time_tracking_source, company: company, source_type: "aire_services", name: "Replacement AIRE")
    create(
      :aire_payroll_calendar_period,
      company: company,
      time_tracking_source: source,
      pay_period: pay_period
    )

    state = described_class.call(pay_period, now: Time.find_zone!("Pacific/Guam").local(2026, 10, 1, 9))

    expect(state).to include(source_id: source.id, source_name: source.name)
    expect(state.fetch(:source_id)).not_to eq(replacement.id)
  end
end
