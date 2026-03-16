# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form941GuAggregator do
  let!(:company)    { create(:company, name: "Guam Biz Inc", ein: "91-1234567") }
  let!(:department) { create(:department, company: company) }
  let!(:employee1)  { create(:employee, company: company, department: department) }
  let!(:employee2)  { create(:employee, company: company, department: department) }

  # Q2 2025: April–June
  let(:q2_start) { Date.new(2025, 4, 1) }
  let(:q2_end)   { Date.new(2025, 6, 30) }

  let!(:pp_april) do
    create(:pay_period, :committed,
      company:    company,
      start_date: Date.new(2025, 4,  1),
      end_date:   Date.new(2025, 4, 14),
      pay_date:   Date.new(2025, 4, 18))
  end

  let!(:pp_may) do
    create(:pay_period, :committed,
      company:    company,
      start_date: Date.new(2025, 5,  1),
      end_date:   Date.new(2025, 5, 14),
      pay_date:   Date.new(2025, 5, 16))
  end

  # April payroll items
  let!(:item_apr_e1) do
    create(:payroll_item,
      pay_period:                  pp_april,
      employee:                    employee1,
      gross_pay:                   2000.00,
      withholding_tax:             100.00,
      social_security_tax:         124.00,
      employer_social_security_tax: 124.00,
      medicare_tax:                 29.00,
      employer_medicare_tax:        29.00,
      reported_tips:               50.00)
  end

  let!(:item_apr_e2) do
    create(:payroll_item,
      pay_period:                  pp_april,
      employee:                    employee2,
      gross_pay:                   1500.00,
      withholding_tax:             75.00,
      social_security_tax:         93.00,
      employer_social_security_tax: 93.00,
      medicare_tax:                21.75,
      employer_medicare_tax:       21.75,
      reported_tips:               0.00)
  end

  # May payroll items (only employee1 this period)
  let!(:item_may_e1) do
    create(:payroll_item,
      pay_period:                  pp_may,
      employee:                    employee1,
      gross_pay:                   2000.00,
      withholding_tax:             100.00,
      social_security_tax:         124.00,
      employer_social_security_tax: 124.00,
      medicare_tax:                 29.00,
      employer_medicare_tax:        29.00,
      reported_tips:               25.00)
  end

  subject(:aggregator) { described_class.new(company, 2025, 2) }

  describe "#initialize" do
    it "accepts valid quarter values" do
      expect { described_class.new(company, 2025, 1) }.not_to raise_error
      expect { described_class.new(company, 2025, 4) }.not_to raise_error
    end

    it "raises ArgumentError for invalid quarter" do
      expect { described_class.new(company, 2025, 0) }.to raise_error(ArgumentError, /quarter must be 1–4/)
      expect { described_class.new(company, 2025, 5) }.to raise_error(ArgumentError, /quarter must be 1–4/)
    end
  end

  describe "#generate" do
    subject(:report) { aggregator.generate }

    describe "meta section" do
      it "includes correct report metadata" do
        expect(report[:meta][:report_type]).to eq("form_941_gu")
        expect(report[:meta][:year]).to eq(2025)
        expect(report[:meta][:quarter]).to eq(2)
        expect(report[:meta][:quarter_label]).to eq("Q2 2025")
        expect(report[:meta][:pay_periods_included]).to eq(2)
        expect(report[:meta][:company_id]).to eq(company.id)
        expect(report[:meta][:company_name]).to eq("Guam Biz Inc")
        expect(report[:meta][:ein]).to eq("91-1234567")
      end

      it "includes caveats about placeholders" do
        expect(report[:meta][:caveats]).to be_an(Array)
        expect(report[:meta][:caveats]).not_to be_empty
        expect(report[:meta][:caveats].any? { |c| c.include?("PLACEHOLDER") }).to be true
      end
    end

    describe "employer_info section" do
      it "includes company identity fields" do
        expect(report[:employer_info][:name]).to eq("Guam Biz Inc")
        expect(report[:employer_info][:ein]).to eq("91-1234567")
      end
    end

    describe "lines section" do
      let(:lines) { report[:lines] }

      it "line1: counts distinct employees" do
        # Q2 line 1 uses employees paid during the pay period containing June 12.
        expect(lines[:line1_employee_count]).to eq(0)
      end

      it "line2: sums wages + tips + other compensation" do
        # Gross pay is already the source of truth for wages/tips compensation.
        expect(lines[:line2_wages_tips_other]).to eq(5500.0)
      end

      it "line3: sums FIT withheld" do
        # 100 + 75 + 100 = 275
        expect(lines[:line3_fit_withheld]).to eq(275.0)
      end

      it "line5a: combined SS tax (employee + employer)" do
        # SS wages exclude the reported_tips portion from gross_pay.
        expect(lines[:line5a_ss_combined_tax]).to eq(672.7)
      end

      it "line5b: SS tips" do
        # 50 + 25 = 75 reported_tips
        expect(lines[:line5b_ss_tips]).to eq(75.0)
        expect(lines[:line5b_ss_tips_combined_tax]).to eq((75.0 * 0.124).round(2))
      end

      it "line5c: combined Medicare tax (employee + employer)" do
        # (29 + 29) + (21.75 + 21.75) + (29 + 29) = 159.5
        expect(lines[:line5c_medicare_combined_tax]).to eq(159.5)
      end

      it "line5d: additional Medicare tax is 0 when wages under threshold" do
        # All wages well under $200K threshold
        expect(lines[:line5d_add_medicare_wages]).to eq(0.0)
        expect(lines[:line5d_add_medicare_tax]).to eq(0.0)
      end

      it "line5e: total SS + Medicare taxes" do
        ss_tips_combined  = (75.0 * 0.124).round(2)
        expected_5e = (672.7 + ss_tips_combined + 159.5 + 0.0).round(2)
        expect(lines[:line5e_total_ss_medicare]).to eq(expected_5e)
      end

      it "line6: total taxes before adjustments (line3 + line5e)" do
        line5e = lines[:line5e_total_ss_medicare]
        expect(lines[:line6_total_taxes_before_adj]).to eq((275.0 + line5e).round(2))
      end

      it "placeholder lines are nil" do
        expect(lines[:line7_adj_fractions_cents]).to be_nil
        expect(lines[:line8_adj_sick_pay]).to be_nil
        expect(lines[:line9_adj_tips_group_life]).to be_nil
        expect(lines[:line11_nonrefundable_credits]).to be_nil
        expect(lines[:line13_total_deposits]).to be_nil
        expect(lines[:line14_balance_due_or_overpayment]).to be_nil
      end

      it "line10 equals line6 when adjustments are nil" do
        expect(lines[:line10_total_taxes_after_adj]).to eq(lines[:line6_total_taxes_before_adj])
      end
    end

    describe "tax_detail section" do
      let(:detail) { report[:tax_detail] }

      it "separates employee and employer SS taxes" do
        # employee SS: 124 + 93 + 124 = 341
        expect(detail[:ss_employee]).to eq(341.0)
        expect(detail[:ss_employer]).to eq(341.0)
        expect(detail[:ss_combined]).to eq(682.0)
      end

      it "separates employee and employer Medicare taxes" do
        # employee Medicare: 29 + 21.75 + 29 = 79.75
        expect(detail[:medicare_employee]).to eq(79.75)
        expect(detail[:medicare_employer]).to eq(79.75)
        expect(detail[:medicare_combined]).to eq(159.5)
      end

      it "totals employee-side taxes" do
        # FIT: 275 + SS emp: 341 + Medicare emp: 79.75 + Add Medicare: 0 = 695.75
        expect(detail[:total_employee_taxes]).to eq(695.75)
      end

      it "totals employer-side taxes" do
        # SS er: 341 + Medicare er: 79.75 = 420.75
        expect(detail[:total_employer_taxes]).to eq(420.75)
      end
    end

    describe "monthly_liability section" do
      let(:breakdown) { report[:monthly_liability] }

      it "returns 3 months for the quarter" do
        expect(breakdown.length).to eq(3)
      end

      it "labels months correctly for Q2" do
        expect(breakdown[0][:month]).to eq("April 2025")
        expect(breakdown[1][:month]).to eq("May 2025")
        expect(breakdown[2][:month]).to eq("June 2025")
      end

      it "calculates April liability" do
        april = breakdown[0]
        # FIT: 175, SS wages: (2000-50)+1500, SS tips: 50, Medicare base: 3500
        expect(april[:fit_withheld].to_f).to eq(175.0)
        expect(april[:ss_combined].to_f).to eq(427.8)
        expect(april[:ss_tips_combined].to_f).to eq(6.2)
        expect(april[:medicare_combined].to_f).to eq(101.5)
        expect(april[:add_medicare_tax].to_f).to eq(0.0)
        expect(april[:total_liability].to_f).to eq(710.5)
      end

      it "calculates May liability" do
        may = breakdown[1]
        # FIT: 100, SS wages: 2000-25, SS tips: 25, Medicare base: 2000
        expect(may[:fit_withheld].to_f).to eq(100.0)
        expect(may[:ss_combined].to_f).to eq(244.9)
        expect(may[:ss_tips_combined].to_f).to eq(3.1)
        expect(may[:medicare_combined].to_f).to eq(58.0)
        expect(may[:add_medicare_tax].to_f).to eq(0.0)
        expect(may[:total_liability].to_f).to eq(406.0)
      end

      it "June has zero liability (no committed pay periods)" do
        june = breakdown[2]
        expect(june[:total_liability].to_f).to eq(0.0)
      end

      it "reconciles monthly liabilities to line6 total" do
        monthly_total = breakdown.sum { |m| m[:total_liability].to_f }.round(2)
        expect(monthly_total).to eq(report[:lines][:line10_total_taxes_after_adj].to_f)
      end

      it "keeps each month total aligned with the published rounded fields" do
        breakdown.each do |month|
          published_total = (
            month[:fit_withheld].to_f +
            month[:ss_combined].to_f +
            month[:ss_tips_combined].to_f +
            month[:medicare_combined].to_f +
            month[:add_medicare_tax].to_f
          ).round(2)

          expect(month[:total_liability].to_f).to eq(published_total)
        end
      end
    end

    describe "excludes non-committed pay periods" do
      let!(:draft_pp) do
        create(:pay_period,
          company:    company,
          start_date: Date.new(2025, 6,  1),
          end_date:   Date.new(2025, 6, 14),
          pay_date:   Date.new(2025, 6, 18),
          status:     "draft")
      end

      let!(:draft_item) do
        create(:payroll_item,
          pay_period:  draft_pp,
          employee:    employee1,
          gross_pay:   9999.00,
          withholding_tax: 999.00)
      end

      it "does not include draft pay period wages in line2" do
        expect(report[:lines][:line2_wages_tips_other]).to eq(5500.0)
      end
    end

    describe "excludes pay periods outside the quarter" do
      let!(:q1_pp) do
        create(:pay_period, :committed,
          company:    company,
          start_date: Date.new(2025, 1,  1),
          end_date:   Date.new(2025, 1, 14),
          pay_date:   Date.new(2025, 3, 31))  # Q1
      end

      let!(:q1_item) do
        create(:payroll_item,
          pay_period:  q1_pp,
          employee:    employee2,
          gross_pay:   8888.00,
          withholding_tax: 888.00)
      end

      it "does not include Q1 wages in Q2 report" do
        expect(report[:lines][:line2_wages_tips_other]).to eq(5500.0)
      end
    end
  end

  describe "Additional Medicare Tax estimation" do
    it "computes excess wages above $200K threshold" do
      high_earner = create(:employee, company: company, department: department)
      pp = create(:pay_period, :committed,
        company:    company,
        start_date: Date.new(2025, 4,  1),
        end_date:   Date.new(2025, 4, 14),
        pay_date:   Date.new(2025, 4, 18))

      # This one employee earned $210K in the quarter (unrealistic but tests the math)
      create(:payroll_item,
        pay_period:                  pp,
        employee:                    high_earner,
        gross_pay:                   210_000.00,
        withholding_tax:             50_000.00,
        social_security_tax:         0.00,      # already capped
        employer_social_security_tax: 0.00,
        medicare_tax:                3045.00,
        employer_medicare_tax:       3045.00)

      report = described_class.new(company, 2025, 2).generate
      # Only the high-earner pushes above $200K
      # Excess: 210_000 - 200_000 = 10_000 (plus any other employees well under threshold)
      expect(report[:lines][:line5d_add_medicare_wages]).to be >= 10_000.0
      expect(report[:lines][:line5d_add_medicare_tax]).to be >= 90.0  # 10_000 * 0.009
    end
  end

  describe "SS tips wage-base cap" do
    it "caps taxable ss tips when employee wages already exceed SS wage base" do
      baseline = described_class.new(company, 2025, 2).generate

      high_wage = create(:employee, company: company, department: department)
      pp = create(:pay_period, :committed,
        company:    company,
        start_date: Date.new(2025, 4, 1),
        end_date:   Date.new(2025, 4, 14),
        pay_date:   Date.new(2025, 4, 18))

      create(:payroll_item,
        pay_period:                   pp,
        employee:                     high_wage,
        gross_pay:                    200_000.00,
        reported_tips:                10_000.00,
        withholding_tax:              0.0,
        social_security_tax:          0.0,
        employer_social_security_tax: 0.0,
        medicare_tax:                 0.0,
        employer_medicare_tax:        0.0)

      report = described_class.new(company, 2025, 2).generate
      # Added employee has no SS headroom left for tips, so line5b should not increase.
      expect(report[:lines][:line5b_ss_tips]).to eq(baseline[:lines][:line5b_ss_tips])
    end
  end

  describe "Additional Medicare tips inclusion" do
    it "counts reported tips toward the $200K threshold" do
      high_earner = create(:employee, company: company, department: department)
      pp = create(:pay_period, :committed,
        company:    company,
        start_date: Date.new(2025, 4, 1),
        end_date:   Date.new(2025, 4, 14),
        pay_date:   Date.new(2025, 4, 18))

      create(:payroll_item,
        pay_period:                   pp,
        employee:                     high_earner,
        gross_pay:                    203_000.00,
        reported_tips:                5_000.00,
        withholding_tax:              0.0,
        social_security_tax:          0.0,
        employer_social_security_tax: 0.0,
        medicare_tax:                 0.0,
        employer_medicare_tax:        0.0)

      report = described_class.new(company, 2025, 2).generate
      expect(report[:lines][:line5d_add_medicare_wages]).to be >= 3_000.0
      expect(report[:lines][:line5d_add_medicare_tax]).to be >= 27.0
    end
  end

  describe "cross-quarter SS wage base headroom" do
    it "does not over-count Q2 taxable tips when SS cap was consumed in Q1" do
      tipped_employee = create(:employee, company: company, department: department)

      q1_pp = create(:pay_period, :committed,
        company:    company,
        start_date: Date.new(2025, 1, 1),
        end_date:   Date.new(2025, 1, 14),
        pay_date:   Date.new(2025, 3, 31))

      # Simulate SS wage base already consumed in Q1 via combined SS tax postings.
      create(:payroll_item,
        pay_period:                   q1_pp,
        employee:                     tipped_employee,
        gross_pay:                    176_100.00,
        reported_tips:                0.0,
        withholding_tax:              0.0,
        social_security_tax:          10_918.2,
        employer_social_security_tax: 10_918.2,
        medicare_tax:                 0.0,
        employer_medicare_tax:        0.0)

      q2_pp = create(:pay_period, :committed,
        company:    company,
        start_date: Date.new(2025, 4, 1),
        end_date:   Date.new(2025, 4, 14),
        pay_date:   Date.new(2025, 4, 18))

      create(:payroll_item,
        pay_period:                   q2_pp,
        employee:                     tipped_employee,
        gross_pay:                    1_000.00,
        reported_tips:                5_000.00,
        withholding_tax:              0.0,
        social_security_tax:          0.0,
        employer_social_security_tax: 0.0,
        medicare_tax:                 0.0,
        employer_medicare_tax:        0.0)

      report = described_class.new(company, 2025, 2).generate
      expect(report[:lines][:line5b_ss_tips]).to eq(75.0)
    end
  end

  describe "line 1 quarter-boundary pay dates" do
    it "counts employees whose pay period spans the 12th even if pay_date falls in the next quarter" do
      boundary_employee = create(:employee, company: company, department: department)
      next_quarter_pay_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 6, 1),
        end_date: Date.new(2025, 6, 15),
        pay_date: Date.new(2025, 7, 1))

      create(:payroll_item,
        pay_period: next_quarter_pay_period,
        employee: boundary_employee,
        gross_pay: 1500.0,
        withholding_tax: 100.0,
        social_security_tax: 93.0,
        employer_social_security_tax: 93.0,
        medicare_tax: 21.75,
        employer_medicare_tax: 21.75)

      report = described_class.new(company, 2025, 2).generate
      expect(report[:lines][:line1_employee_count]).to eq(1)
    end
  end

  describe "fractions-of-cents adjustment" do
    it "uses line 7 to reconcile monthly liability rounding to quarter totals" do
      company = create(:company, name: "Rounding Test Co")
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department)

      q1_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 3, 1),
        end_date: Date.new(2025, 3, 14),
        pay_date: Date.new(2025, 3, 15))

      create(:payroll_item,
        pay_period: q1_period,
        employee: employee,
        gross_pay: 176_100.0,
        withholding_tax: 0.0,
        social_security_tax: 10_918.2,
        employer_social_security_tax: 10_918.2,
        medicare_tax: 0.0,
        employer_medicare_tax: 0.0,
        reported_tips: 0.0)

      [
        Date.new(2025, 4, 15),
        Date.new(2025, 5, 15),
        Date.new(2025, 6, 15)
      ].zip([ 333.33, 333.33, 333.34 ]).each do |pay_date, gross_pay|
        period = create(:pay_period, :committed,
          company: company,
          start_date: pay_date - 14.days,
          end_date: pay_date - 1.day,
          pay_date: pay_date)

        create(:payroll_item,
          pay_period: period,
          employee: employee,
          gross_pay: gross_pay,
          withholding_tax: 0.0,
          social_security_tax: 0.0,
          employer_social_security_tax: 0.0,
          medicare_tax: (gross_pay * 0.0145).round(2),
          employer_medicare_tax: (gross_pay * 0.0145).round(2),
          reported_tips: 0.0)
      end

      report = described_class.new(company, 2025, 2).generate
      monthly_total = report[:monthly_liability].sum { |month| month[:total_liability].to_f }.round(2)

      expect(report[:lines][:line5c_medicare_combined_tax]).to eq(29.0)
      expect(monthly_total).to eq(29.01)
      expect(report[:lines][:line7_adj_fractions_cents]).to eq(0.01)
      expect(report[:lines][:line10_total_taxes_after_adj]).to eq(monthly_total)
    end
  end
end
