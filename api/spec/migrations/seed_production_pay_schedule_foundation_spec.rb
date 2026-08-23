# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260803121000_seed_production_pay_schedule_foundation")

RSpec.describe SeedProductionPayScheduleFoundation do
  it "is idempotent and relabels Spike pay period 43 without changing money" do
    company = create(:company, name: "Spike Coffee Roasters LLC", pay_frequency: "biweekly")
    period = create(
      :pay_period,
      id: 43,
      company: company,
      start_date: Date.new(2026, 4, 4),
      end_date: Date.new(2026, 5, 15),
      pay_date: Date.new(2026, 5, 18),
      status: "committed"
    )
    regular_period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 5, 17),
      end_date: Date.new(2026, 5, 30),
      pay_date: Date.new(2026, 6, 5),
      status: "committed"
    )
    employee = create(:employee, company: company, department: create(:department, company: company))
    item = create(:payroll_item, pay_period: period, company: company, employee: employee, gross_pay: 425.50, net_pay: 390.25)

    2.times { described_class.new.up }

    expect(company.company_pay_schedules.count).to eq(1)
    expect(company.company_workweeks.count).to eq(1)
    expect(company.company_pay_schedules.first).to have_attributes(
      effective_on: Date.new(2026, 5, 17),
      period_anchor_date: Date.new(2026, 5, 17),
      period_rule: "biweekly"
    )
    expect(period.reload).to have_attributes(
      run_purpose: "off_cycle_tips",
      includes_base_salary: false,
      run_purpose_source: "production_migration"
    )
    expect(period.company_pay_schedule).to be_nil
    expect(period.company_workweek).to be_present
    expect(regular_period.reload.company_pay_schedule).to be_present
    expect(regular_period.company_workweek).to be_present
    expect(item.reload).to have_attributes(gross_pay: 425.50, net_pay: 390.25)

    seeded_schedule = company.company_pay_schedules.first
    seeded_workweek = company.company_workweeks.first
    seeded_schedule.update!(ends_on: Date.new(2026, 6, 6))
    seeded_workweek.update!(ends_on: Date.new(2026, 6, 6))
    operator_schedule = company.company_pay_schedules.create!(
      frequency: "biweekly",
      period_rule: "biweekly",
      period_start_weekday: 0,
      period_anchor_date: Date.new(2026, 6, 7),
      pay_date_rule: "days_after_period_end",
      pay_date_offset_days: 6,
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: create(:user, company: company),
      confirmed_at: Time.current,
      notes: "Confirmed by employer",
      effective_on: Date.new(2026, 6, 7)
    )
    operator_workweek = company.company_workweeks.create!(
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: operator_schedule.confirmed_by,
      confirmed_at: Time.current,
      notes: "Confirmed by employer",
      effective_on: Date.new(2026, 6, 7)
    )
    regular_period.update!(
      company_pay_schedule: operator_schedule,
      company_workweek: operator_workweek
    )

    described_class.new.down

    expect(period.reload).to have_attributes(
      company_pay_schedule_id: nil,
      company_workweek_id: nil,
      run_purpose: "regular",
      includes_base_salary: true
    )
    expect(regular_period.reload).to have_attributes(
      company_pay_schedule_id: operator_schedule.id,
      company_workweek_id: operator_workweek.id
    )
    expect(company.company_pay_schedules.reload).to contain_exactly(operator_schedule)
    expect(company.company_workweeks.reload).to contain_exactly(operator_workweek)
    expect(item.reload).to have_attributes(gross_pay: 425.50, net_pay: 390.25)
  end
end
