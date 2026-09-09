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

    it "includes W-4 Step 4(c) extra withholding in Form 500 and W-1 reconciliation" do
      period = create_committed_period(
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 14),
        pay_date: Date.new(2026, 4, 17)
      )
      item = create_item(pay_period: period, gross_pay: 1_000)
      item.update!(withholding_tax: 100, additional_withholding: 25, net_pay: 850)

      report = described_class.new(company, 2026, 2).generate

      expect(report.dig(:form_500, :total_guam_withholding)).to eq(125.0)
      expect(report.dig(:w1, :total_guam_withholding)).to eq(125.0)
      expect(report.dig(:pay_periods, 0, :guam_withholding)).to eq(125.0)
    end

    it "uses locked QuickBooks payroll in quarterly reports without recreating its payments" do
      imported = create_historical_filing_source(
        company: company,
        employee: employee,
        pay_date: Date.new(2026, 4, 10),
        gross_pay: 1_000,
        federal_income_tax: 80,
        social_security_tax: 62,
        medicare_tax: 14.50,
        employer_social_security_tax: 62,
        employer_medicare_tax: 14.50
      )
      live_period = create_committed_period(
        start_date: Date.new(2026, 4, 7),
        end_date: Date.new(2026, 4, 20),
        pay_date: Date.new(2026, 4, 24)
      )
      live_item = create_item(pay_period: live_period, gross_pay: 2_000)
      live_item.update!(withholding_tax: 100, net_pay: 1_871)

      report = described_class.new(company, 2026, 2).generate
      imported_period = report[:pay_periods].find { |row| row[:source] == "quickbooks" }

      expect(report.dig(:meta, :source_summary, :cornerstone, :pay_period_count)).to eq(1)
      expect(report.dig(:meta, :source_summary, :quickbooks, :pay_period_count)).to eq(1)
      expect(report.dig(:w1, :total_guam_withholding)).to eq(180.0)
      expect(report.dig(:swica, :totals, :total_wages)).to eq(3_000.0)
      expect(report.dig(:federal_941, :report, :meta, :source_summary, :quickbooks, :included)).to be(true)
      expect(imported_period).to include(
        id: "quickbooks:period:#{imported.fetch(:period).id}",
        source: "quickbooks",
        read_only: true,
        payment_status: "paid_before_cornerstone",
        gross_pay: 1_000.0
      )

      expect(report.dig(:form_500, :total_guam_withholding)).to eq(100.0)
      expect(report.dig(:form_500, :excluded_historical_withholding)).to eq(80.0)
      expect(report.dig(:form_500, :deposits).map { |row| row[:pay_period_id] }).to eq([ live_period.id ])
    end

    it "does not add Additional Medicare twice when a committed item already stores it" do
      prior_period = create_committed_period(
        start_date: Date.new(2026, 3, 1),
        end_date: Date.new(2026, 3, 15),
        pay_date: Date.new(2026, 3, 20)
      )
      current_period = create_committed_period(
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 14),
        pay_date: Date.new(2026, 4, 17)
      )
      create_item(pay_period: prior_period, gross_pay: 199_000)
      current = create_item(pay_period: current_period, gross_pay: 2_000)
      current.update!(
        medicare_tax: 38,
        employer_medicare_tax: 29,
        medicare_taxable_wages: 2_000,
        additional_medicare_taxable_wages: 1_000
      )

      report = described_class.new(company, 2026, 2).generate

      expect(report.dig(:pay_periods, 0, :federal_941_liability)).to eq(67.0)
      expect(report.dig(:swica, :employees, 0, :federal_941_liability)).to eq(67.0)
    end

    it "flags contractor-tagged payroll that contains W-2 tax amounts" do
      period = create_committed_period(
        start_date: Date.new(2026, 6, 16),
        end_date: Date.new(2026, 6, 30),
        pay_date: Date.new(2026, 6, 30)
      )
      item = create(:payroll_item,
        company: company,
        employee: employee,
        pay_period: period,
        employment_type: "contractor",
        gross_pay: 72.52,
        net_pay: 66.97,
        withholding_tax: 0,
        social_security_tax: 4.50,
        employer_social_security_tax: 4.50,
        medicare_tax: 1.05,
        employer_medicare_tax: 1.05)

      report = described_class.new(company, 2026, 2).generate
      check = report[:review_checks].find { |row| row[:key] == "employment_tax_classification_consistent" }

      expect(report.dig(:swica, :excluded_contractor_summary)).to eq(
        employee_count: 1,
        item_count: 1,
        total_wages: 72.52
      )
      expect(check[:status]).to eq("needs_review")
      expect(check.dig(:details, :issue_count)).to eq(1)
      expect(check.dig(:details, :issues, 0)).to include(
        payroll_item_id: item.id,
        employee_id: employee.id,
        gross_pay: 72.52,
        employee_tax: 5.55,
        employer_tax: 5.55
      )
    end
  end
end
