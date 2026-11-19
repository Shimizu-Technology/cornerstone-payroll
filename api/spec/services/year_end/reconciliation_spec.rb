# frozen_string_literal: true

require "rails_helper"

RSpec.describe YearEnd::Reconciliation do
  let(:company) { create(:company, ein: "98-7654321") }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department) }

  def pay(pay_date, **amounts)
    period = create(:pay_period, :committed, company: company,
      start_date: pay_date - 17.days, end_date: pay_date - 3.days, pay_date: pay_date)
    create(:payroll_item, {
      company: company, employee: employee, pay_period: period,
      gross_pay: 2_000, net_pay: 1_600, withholding_tax: 150,
      social_security_tax: 124, employer_social_security_tax: 124,
      medicare_tax: 29, employer_medicare_tax: 29,
      social_security_taxable_wages: 2_000, social_security_taxable_tips: 0, medicare_taxable_wages: 2_000,
      fit_taxable_wages: amounts.fetch(:gross_pay, 2_000)
    }.merge(amounts))
  end

  def line(result, key)
    result[:lines].find { |entry| entry[:key] == key }
  end

  it "matches the W-2GU totals to the four 941 quarters and the W-1s" do
    pay(Date.new(2026, 2, 6))
    pay(Date.new(2026, 8, 7))
    w2 = W2GuAggregator.new(company, 2026).generate

    result = described_class.new(company: company, year: 2026, w2_report: w2).call

    expect(result[:status]).to eq("match")
    expect(result[:blockers]).to be_empty
    expect(result[:lines].map { |entry| entry[:key] }).to eq(%w[
      social_security_wages social_security_tips medicare_wages social_security_tax medicare_tax guam_income_tax
    ])
    expect(line(result, "social_security_wages")).to include(
      w2_total: 4_000.0, quarterly_total: 4_000.0, opening_balances: 0.0, difference: 0.0, status: "match"
    )
    expect(line(result, "social_security_wages")[:quarters].map { |quarter| quarter[:amount] }).to eq([ 2_000.0, 0.0, 2_000.0, 0.0 ])
    expect(line(result, "guam_income_tax")).to include(w2_total: 300.0, quarterly_total: 300.0, source: "w1", difference: 0.0)
    expect(line(result, "medicare_tax")).to include(w2_total: 58.0, quarterly_total: 58.0)
  end

  it "blocks on a Social Security wage difference and names the quarter whose 941 disagrees" do
    pay(Date.new(2026, 2, 6))
    # A stored wage base without a stored tip base sends the 941 down its
    # legacy fallback (gross less tips) while the W-2GU sums the stored base.
    pay(Date.new(2026, 5, 8), gross_pay: 2_000, social_security_taxable_wages: 1_800, social_security_taxable_tips: nil,
      social_security_tax: 111.60, employer_social_security_tax: 111.60)
    w2_report = { totals: {
      box3_social_security_wages: 3_800.0, box7_social_security_tips: 0.0, box5_medicare_wages_tips: 4_000.0,
      box4_social_security_tax_withheld: 235.6, box6_medicare_tax_withheld: 58.0, box2_federal_income_tax_withheld: 300.0
    } }

    result = described_class.new(company: company, year: 2026, w2_report: w2_report).call

    expect(result[:status]).to eq("mismatch")
    wages = line(result, "social_security_wages")
    expect(wages).to include(w2_total: 3_800.0, quarterly_total: 4_000.0, difference: -200.0, status: "mismatch")
    expect(wages[:quarters][1]).to include(quarter: 2, amount: 2_000.0, payroll_records: 1_800.0, difference: 200.0)
    expect(wages[:look_at]).to contain_exactly(a_hash_including(kind: "quarter", quarter: 2, label: "Q2 941"))
    expect(wages[:message]).to eq("W-2 Box 3 (Social Security wages) is $200.00 less than the 941s and opening balances. Look at the Q2 941.")
    expect(result[:blockers]).to contain_exactly(
      a_hash_including(code: "RECONCILIATION_MISMATCH", line: "social_security_wages", message: wages[:message]),
      # The same row also withheld less than the 941's employee share on its rebuilt base.
      a_hash_including(code: "FORM_941_WITHHOLDING_MISMATCH", quarter: 2)
    )
    expect(line(result, "medicare_wages")[:status]).to eq("match")
  end

  it "names the W-2GU report when every quarter agrees with its payroll records" do
    pay(Date.new(2026, 2, 6))
    w2_report = { totals: {
      box3_social_security_wages: 2_000.0, box7_social_security_tips: 0.0, box5_medicare_wages_tips: 2_000.0,
      box4_social_security_tax_withheld: 124.0, box6_medicare_tax_withheld: 29.0, box2_federal_income_tax_withheld: 160.0
    } }

    result = described_class.new(company: company, year: 2026, w2_report: w2_report).call

    guam = line(result, "guam_income_tax")
    expect(guam).to include(status: "mismatch", difference: 10.0)
    expect(guam[:look_at]).to contain_exactly(a_hash_including(kind: "w2_report"))
    expect(guam[:message]).to include("$10.00 more than the W-1s")
  end

  it "keeps opening balances for quarters before cutover as their own column" do
    create_historical_filing_source(
      company: company, employee: employee, pay_date: Date.new(2026, 6, 30),
      gross_pay: 12_000, federal_income_tax: 900, social_security_tax: 744, medicare_tax: 174,
      employer_social_security_tax: 744, employer_medicare_tax: 174,
      period_type: "opening_summary", period_start: Date.new(2026, 1, 1), period_end: Date.new(2026, 6, 30)
    )
    pay(Date.new(2026, 8, 7))
    pay(Date.new(2026, 11, 6))
    w2 = W2GuAggregator.new(company, 2026).generate

    result = described_class.new(company: company, year: 2026, w2_report: w2).call

    expect(result[:status]).to eq("match"), result[:blockers].inspect
    expect(result[:opening_balances]).to include(present: true, first_pay_date: "2026-01-01", last_pay_date: "2026-06-30")
    wages = line(result, "social_security_wages")
    expect(wages).to include(w2_total: 16_000.0, quarterly_total: 4_000.0, opening_balances: 12_000.0, difference: 0.0)
    expect(wages[:quarters].map { |quarter| quarter[:amount] }).to eq([ 0.0, 0.0, 2_000.0, 2_000.0 ])
    expect(line(result, "guam_income_tax")).to include(w2_total: 1_200.0, quarterly_total: 300.0, opening_balances: 900.0, difference: 0.0)
  end

  it "reports the comparison as unavailable when a quarter cannot be built" do
    allow(Form941GuAggregator).to receive(:new).and_raise(ArgumentError, "SS wage base not configured for 2026")

    result = described_class.new(company: company, year: 2026, w2_report: { totals: {} }).call

    expect(result[:status]).to eq("unavailable")
    expect(result[:blockers]).to contain_exactly(a_hash_including(code: "RECONCILIATION_UNAVAILABLE"))
  end

  describe "the Social Security wage base" do
    it "matches capped opening balances using the YTD bridge allocation" do
      create_historical_filing_source(
        company: company, employee: employee, pay_date: Date.new(2026, 6, 30),
        gross_pay: 200_000, federal_income_tax: 20_000, social_security_tax: 11_439, medicare_tax: 2_900,
        employer_social_security_tax: 11_439, employer_medicare_tax: 2_900, social_security_taxable_wages: 184_500,
        period_type: "opening_summary", period_start: Date.new(2026, 1, 1), period_end: Date.new(2026, 6, 30)
      )
      # Over the wage base and the $200,000 Additional Medicare threshold.
      pay(Date.new(2026, 8, 7), social_security_taxable_wages: 0, social_security_tax: 0, employer_social_security_tax: 0, medicare_tax: 47)
      w2 = W2GuAggregator.new(company, 2026).generate

      result = described_class.new(company: company, year: 2026, w2_report: w2).call

      expect(result[:status]).to eq("match"), result[:blockers].inspect
      expect(line(result, "social_security_wages")).to include(w2_total: 184_500.0, quarterly_total: 0.0, opening_balances: 184_500.0, difference: 0.0)
      expect(line(result, "medicare_wages")).to include(w2_total: 202_000.0, opening_balances: 200_000.0, difference: 0.0)
    end

    it "explains a legacy tipped employee's wage/tip split at the wage base when the Social Security total matches" do
      # Legacy rows (no stored bases): the 941s cap paycheck by paycheck, so the
      # early tips fit under the base; the W-2 caps wages first for the year.
      pay(Date.new(2026, 2, 6), gross_pay: 10_000, reported_tips: 5_000,
        social_security_taxable_wages: nil, social_security_taxable_tips: nil, medicare_taxable_wages: nil,
        social_security_tax: 620, employer_social_security_tax: 620, medicare_tax: 145, employer_medicare_tax: 145)
      pay(Date.new(2026, 5, 8), gross_pay: 180_000,
        social_security_taxable_wages: nil, social_security_taxable_tips: nil, medicare_taxable_wages: nil,
        social_security_tax: 10_819, employer_social_security_tax: 10_819, medicare_tax: 2_610, employer_medicare_tax: 2_610)
      w2 = W2GuAggregator.new(company, 2026).generate

      result = described_class.new(company: company, year: 2026, w2_report: w2).call

      expect(result[:status]).to eq("match"), result[:blockers].inspect
      expect(line(result, "social_security_wages")).to include(w2_total: 184_500.0, quarterly_total: 179_500.0, difference: 5_000.0, status: "explained")
      expect(line(result, "social_security_tips")).to include(w2_total: 0.0, quarterly_total: 5_000.0, difference: -5_000.0, status: "explained")
      expect(line(result, "social_security_wages")[:note]).to include("Box 3 + Box 7 equals lines 5a + 5b")
    end

    it "still blocks a wage/tip split that is not explained by employees at the wage base" do
      pay(Date.new(2026, 2, 6))
      w2_report = { employees: [], totals: {
        box3_social_security_wages: 2_100.0, box7_social_security_tips: -100.0, box5_medicare_wages_tips: 2_000.0,
        box4_social_security_tax_withheld: 124.0, box6_medicare_tax_withheld: 29.0, box2_federal_income_tax_withheld: 150.0
      } }

      result = described_class.new(company: company, year: 2026, w2_report: w2_report).call

      expect(result[:status]).to eq("mismatch")
      expect(result[:blockers].map { |blocker| blocker[:line] }).to contain_exactly("social_security_wages", "social_security_tips")
    end
  end

  describe "each 941's own withholding reconciliation" do
    it "blocks Social Security wages with no Social Security withheld and names the quarter" do
      pay(Date.new(2026, 5, 8), social_security_tax: 0, employer_social_security_tax: 124)
      w2 = W2GuAggregator.new(company, 2026).generate

      result = described_class.new(company: company, year: 2026, w2_report: w2).call

      expect(result[:lines]).to all(include(status: "match"))
      expect(result[:status]).to eq("mismatch")
      expect(result[:form_941_reviews]).to contain_exactly(a_hash_including(quarter: 2, status: "unexplained", employee_difference: -124.0))
      expect(result[:blockers]).to contain_exactly(a_hash_including(
        code: "FORM_941_WITHHOLDING_MISMATCH", quarter: 2,
        message: a_string_including("The Q2 941", "$124.00 less")
      ))
    end

    it "passes an employer rounding residual through for review instead of blocking" do
      pay(Date.new(2026, 5, 8), employer_social_security_tax: 124.03)
      w2 = W2GuAggregator.new(company, 2026).generate

      result = described_class.new(company: company, year: 2026, w2_report: w2).call

      expect(result[:status]).to eq("match"), result[:blockers].inspect
      expect(result[:form_941_reviews]).to contain_exactly(a_hash_including(quarter: 2, status: "residual", recorded_liability_residual: 0.03))
    end
  end
end
