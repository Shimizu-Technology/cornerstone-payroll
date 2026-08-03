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
  end
end
