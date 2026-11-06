# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompanyPaySchedule do
  let(:company) { create(:company) }
  let(:confirmer) { create(:user, company: company) }

  describe "scheduled_pay_date_for" do
    it "returns no scheduled date without a period end" do
      schedule = described_class.new(pay_date_rule: "days_after_period_end", pay_date_offset_days: 5)
      expect(schedule.scheduled_pay_date_for(nil)).to be_nil
    end

    [ 0, 5 ].each do |offset|
      it "keeps the fixed period-end offset of #{offset} days" do
        schedule = described_class.new(pay_date_rule: "days_after_period_end", pay_date_offset_days: offset)
        expect(schedule.scheduled_pay_date_for(Date.new(2026, 10, 31))).to eq(Date.new(2026, 10, 31) + offset)
      end
    end
  end

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
