# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuarterlyCompliancePacketBuilder do
  describe "#generate" do
    let(:company) { create(:company) }
    let(:department) { create(:department, company: company) }
    let(:employee) { create(:employee, company: company, department: department) }

    def create_committed_period(start_date:, end_date:, pay_date:)
      create(:pay_period, :committed,
        company: company,
        start_date: start_date,
        end_date: end_date,
        pay_date: pay_date)
    end

    def create_item(pay_period:, gross_pay:, employee: nil)
      employee ||= self.employee

      create(:payroll_item,
        company: company,
        employee: employee,
        pay_period: pay_period,
        gross_pay: gross_pay,
        net_pay: 0,
        withholding_tax: 0,
        social_security_tax: 0,
        employer_social_security_tax: 0,
        medicare_tax: (gross_pay * 0.0145).round(2),
        employer_medicare_tax: (gross_pay * 0.0145).round(2))
    end

    it "allocates Additional Medicare Tax into the pay-date 941 liability rows" do
      prior_period = create_committed_period(
        start_date: Date.new(2026, 3, 1),
        end_date: Date.new(2026, 3, 15),
        pay_date: Date.new(2026, 3, 20)
      )
      first_q2_period = create_committed_period(
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 14),
        pay_date: Date.new(2026, 4, 16)
      )
      second_q2_period = create_committed_period(
        start_date: Date.new(2026, 4, 15),
        end_date: Date.new(2026, 4, 28),
        pay_date: Date.new(2026, 4, 30)
      )

      create_item(pay_period: prior_period, gross_pay: 199_000.00)
      create_item(pay_period: first_q2_period, gross_pay: 500.00)
      create_item(pay_period: second_q2_period, gross_pay: 1_000.00)

      report = described_class.new(company, 2026, 2).generate
      rows_by_pay_date = report[:pay_periods].index_by { |row| row[:pay_date] }
      employee_row = report.dig(:swica, :employees).find { |row| row[:employee_id] == employee.id }

      expect(rows_by_pay_date["2026-04-16"][:federal_941_liability]).to eq(14.5)
      expect(rows_by_pay_date["2026-04-30"][:federal_941_liability]).to eq(33.5)
      expect(employee_row[:federal_941_liability]).to eq(48.0)
      expect(report.dig(:federal_941, :report, :lines, :line5d_add_medicare_tax)).to eq(4.5)
    end

    it "includes Additional Medicare Tax in the federal deposit schedule lookback" do
      lookback_period = create_committed_period(
        start_date: Date.new(2025, 6, 1),
        end_date: Date.new(2025, 6, 14),
        pay_date: Date.new(2025, 6, 20)
      )

      create(:payroll_item,
        company: company,
        employee: employee,
        pay_period: lookback_period,
        gross_pay: 1_700_000.00,
        net_pay: 0,
        withholding_tax: 0,
        social_security_tax: 0,
        employer_social_security_tax: 0,
        medicare_tax: 24_650.00,
        employer_medicare_tax: 24_650.00)

      report = described_class.new(company, 2026, 2).generate

      expect(report.dig(:federal_941, :deposit_schedule, :suggested_schedule)).to eq("semiweekly")
      expect(report.dig(:federal_941, :deposit_schedule, :schedule_b_required)).to be(true)
    end
  end
end
