# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuarterlyComplianceOfficialForms::ScheduleB do
  describe "#federal_daily_liability" do
    it "groups same-day liabilities before rendering Schedule B day cells" do
      report = {
        meta: {
          company_name: "Cornerstone Tax Services",
          ein: "12-3456789",
          year: 2026,
          quarter: 2,
          quarter_end: "2026-06-30"
        },
        federal_941: { report: { employer_info: {}, lines: {} } },
        pay_periods: [
          { pay_date: "2026-04-16", federal_941_liability: 100.25 },
          { pay_date: "2026-04-16", federal_941_liability: 50.75 },
          { pay_date: "2026-05-01", federal_941_liability: 25.00 }
        ]
      }

      rows = described_class.new(report: report).send(:federal_daily_liability)

      expect(rows).to eq([
        { pay_date: "2026-04-16", month: 4, amount: 151.0 },
        { pay_date: "2026-05-01", month: 5, amount: 25.0 }
      ])
    end

    it "uses edited daily liability rows when previewing reviewed form values" do
      report = {
        meta: {
          company_name: "Cornerstone Tax Services",
          ein: "12-3456789",
          year: 2026,
          quarter: 2,
          quarter_end: "2026-06-30"
        },
        federal_941: { report: { employer_info: {}, lines: {} } },
        pay_periods: [
          { pay_date: "2026-04-16", federal_941_liability: 100.25 }
        ]
      }
      fields = {
        daily_liabilities: [
          { pay_date: "2026-04-16", amount: 125.25 },
          { pay_date: "2026-07-01", amount: 999.0 }
        ]
      }

      rows = described_class.new(report: report, fields: fields).send(:federal_daily_liability)

      expect(rows).to eq([
        { pay_date: "2026-04-16", month: 4, amount: 125.25 }
      ])
    end
  end
end

RSpec.describe QuarterlyComplianceOfficialForms::W1 do
  describe "#generate" do
    it "derives liability months from pay dates when reviewed rows omit month" do
      report = {
        meta: {
          company_name: "Cornerstone Tax Services",
          ein: "12-3456789",
          year: 2026,
          quarter: 2,
          quarter_end: "2026-06-30"
        },
        w1: {
          daily_liabilities: [],
          total_guam_withholding: 125.25
        }
      }
      fields = {
        daily_liabilities: [
          { pay_date: "2026-04-16", amount: 125.25 },
          { pay_date: "2026-07-01", amount: 999.0 }
        ],
        total_guam_withholding: 125.25
      }

      pdf = described_class.new(report: report, fields: fields).generate

      expect(pdf.bytes.first(4)).to eq([ 0x25, 0x50, 0x44, 0x46 ])
    end
  end
end
