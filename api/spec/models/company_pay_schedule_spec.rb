# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompanyPaySchedule do
  let(:company) { create(:company) }
  let(:confirmer) { create(:user, company: company) }

  it "resolves the configuration effective for a payroll date" do
    old_schedule = described_class.create!(
      company: company,
      frequency: "biweekly",
      period_rule: "manual",
      pay_date_rule: "manual",
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1),
      ends_on: Date.new(2026, 6, 30)
    )
    current_schedule = described_class.create!(
      company: company,
      frequency: "semimonthly",
      period_rule: "semimonthly",
      pay_date_rule: "manual",
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: confirmer,
      confirmed_at: Time.current,
      notes: "Confirmed by the employer",
      effective_on: Date.new(2026, 7, 1)
    )

    expect(described_class.for_date(company.id, Date.new(2026, 6, 15))).to eq(old_schedule)
    expect(described_class.for_date(company.id, Date.new(2026, 7, 15))).to eq(current_schedule)
  end

  it "requires a start weekday for an automatic biweekly rule" do
    schedule = described_class.new(
      company: company,
      frequency: "biweekly",
      period_rule: "biweekly",
      pay_date_rule: "manual",
      effective_on: Date.current
    )

    expect(schedule).not_to be_valid
    expect(schedule.errors[:period_start_weekday]).to include("is required for weekly and biweekly schedules")
    expect(schedule.errors[:period_anchor_date]).to include("is required for a biweekly schedule")
  end

  it "requires a biweekly anchor on the configured start weekday" do
    schedule = described_class.new(
      company: company,
      frequency: "biweekly",
      period_rule: "biweekly",
      period_start_weekday: 0,
      period_anchor_date: Date.new(2026, 8, 10),
      pay_date_rule: "manual",
      effective_on: Date.current
    )

    expect(schedule).not_to be_valid
    expect(schedule.errors[:period_anchor_date]).to include("must fall on the configured period start weekday")
  end

  it "requires confirmation evidence before a rule is marked confirmed" do
    schedule = described_class.new(
      company: company,
      frequency: "semimonthly",
      period_rule: "semimonthly",
      pay_date_rule: "manual",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      effective_on: Date.current
    )

    expect(schedule).not_to be_valid
    expect(schedule.errors[:confirmed_by]).to include("can't be blank")
    expect(schedule.errors[:notes]).to include("can't be blank")
  end
end
