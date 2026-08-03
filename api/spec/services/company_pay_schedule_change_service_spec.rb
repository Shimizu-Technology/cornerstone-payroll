# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompanyPayScheduleChangeService do
  let(:company) { create(:company, pay_frequency: "biweekly") }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:schedule_attributes) do
    {
      frequency: "biweekly",
      period_rule: "biweekly",
      period_start_weekday: 0,
      period_anchor_date: Date.new(2026, 8, 9),
      pay_date_rule: "days_after_period_end",
      pay_date_offset_days: 6,
      timezone: "Pacific/Guam",
      notes: "Confirmed by employer"
    }
  end
  let(:workweek_attributes) do
    {
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      notes: "Confirmed by employer"
    }
  end

  before do
    company.company_pay_schedules.create!(
      frequency: "biweekly",
      period_rule: "manual",
      pay_date_rule: "manual",
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1)
    )
    company.company_workweeks.create!(
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1)
    )
    allow_any_instance_of(described_class).to receive(:configuration_date).and_return(Date.new(2026, 8, 3))
  end

  it "does not silently replace a queued future configuration" do
    described_class.call!(
      company: company,
      actor: actor,
      effective_on: Date.new(2026, 8, 10),
      schedule_attributes: schedule_attributes,
      workweek_attributes: workweek_attributes
    )
    queued_schedule = company.company_pay_schedules.find_by!(ends_on: nil)
    queued_workweek = company.company_workweeks.find_by!(ends_on: nil)

    expect do
      described_class.call!(
        company: company,
        actor: actor,
        effective_on: Date.new(2026, 8, 24),
        schedule_attributes: schedule_attributes.merge(period_anchor_date: Date.new(2026, 8, 23)),
        workweek_attributes: workweek_attributes
      )
    end.to raise_error(described_class::ChangeError, /future configuration is already scheduled for 2026-08-10/)

    expect(queued_schedule.reload).to have_attributes(ends_on: nil, effective_on: Date.new(2026, 8, 10))
    expect(queued_workweek.reload).to have_attributes(ends_on: nil, effective_on: Date.new(2026, 8, 10))
    expect(company.company_pay_schedules.count).to eq(2)
    expect(company.company_workweeks.count).to eq(2)
  end
end
