# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollIntake::WorkweekEvidence do
  let(:company) { create(:company, pay_frequency: frequency) }
  let(:staff) { create(:user, company: company, role: "admin") }
  let(:run) { create(:pay_period, company: company, start_date: period_start, end_date: period_end, pay_date: period_end + 5) }

  before do
    CompanyWorkweek.create!(company: company, starts_on_weekday: 0, starts_at_minutes: 0,
      timezone: "Pacific/Guam", effective_on: Date.new(2026, 1, 1), source: "operator_confirmed",
      confirmation_status: "confirmed", confirmed_by: staff, confirmed_at: Time.current, notes: "Synthetic workweek")
  end

  context "weekly payroll" do
    let(:frequency) { "weekly" }
    let(:period_start) { Date.new(2026, 6, 14) }
    let(:period_end) { Date.new(2026, 6, 20) }

    it "captures a single complete legal workweek for weekly overtime calculation" do
      pending "Track C schedules still require a 14-day period"
      expect(described_class.new(pay_period: run).capture!).to include("legal_week_starts" => [ "2026-06-14" ])
    end
  end

  context "semimonthly payroll" do
    let(:frequency) { "semimonthly" }
    let(:period_start) { Date.new(2026, 6, 16) }
    let(:period_end) { Date.new(2026, 6, 30) }

    it "accepts a partial-workweek boundary when the source supplies the overtime split" do
      pending "Track C schedules still require a 14-day period"
      expect(described_class.new(pay_period: run, allow_misaligned: true).capture!).to include(
        "pay_period_start" => "2026-06-16", "pay_period_end" => "2026-06-30", "aligned_with_pay_period" => false
      )
    end
  end

  context "monthly payroll" do
    let(:frequency) { "monthly" }
    let(:period_start) { Date.new(2026, 6, 1) }
    let(:period_end) { Date.new(2026, 6, 30) }

    it "captures the full month when the source supplies the overtime split" do
      pending "Track C schedules still require a 14-day period"
      expect(described_class.new(pay_period: run, allow_misaligned: true).capture!).to include(
        "pay_period_start" => "2026-06-01", "pay_period_end" => "2026-06-30", "aligned_with_pay_period" => false
      )
    end
  end
end
