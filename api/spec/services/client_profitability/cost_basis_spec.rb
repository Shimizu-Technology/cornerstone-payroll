# frozen_string_literal: true

require "rails_helper"

# "Count pay by": pay date (matches the Annual Payroll Summary) or work
# period (each paycheck spread over the days of its pay period).
RSpec.describe "Client profitability cost basis" do
  let(:practice) { create(:company, name: "Cornerstone") }
  let(:organization) { practice.organization }
  let(:acme) { create(:company, organization: organization, name: "Acme Bakery") }
  let(:mark) { create(:employee, company: practice, first_name: "Mark", last_name: "Santos") }
  let!(:settings) { ClientProfitabilitySetting.create!(organization: organization, practice_company: practice) }

  def paycheck(start_date, end_date, pay_date, gross)
    period = create(:pay_period, :committed, company: practice, start_date: start_date, end_date: end_date, pay_date: pay_date)
    create(:payroll_item, company: practice, employee: mark, pay_period: period, gross_pay: gross)
  end

  before do
    paycheck(Date.new(2026, 11, 1), Date.new(2026, 11, 15), Date.new(2026, 11, 20), 1500)
    # Work from Nov 16 to Dec 15 (30 days), paid Dec 20: half of it was worked in November.
    paycheck(Date.new(2026, 11, 16), Date.new(2026, 12, 15), Date.new(2026, 12, 20), 3000)
    import = WorkHourImport.create!(organization: organization, range_start: Date.new(2026, 11, 1), range_end: Date.new(2026, 12, 31),
                                    status: "succeeded")
    WorkHourClientLink.create!(organization: organization, tax_client_id: 1, disposition: "company", company: acme)
    WorkHourStaffLink.create!(organization: organization, tax_user_id: 12, disposition: "employee", employee: mark)
    [ Date.new(2026, 11, 10), Date.new(2026, 12, 10) ].each do |work_date|
      WorkHourRow.create!(organization: organization, work_hour_import: import, tax_user_id: 12, work_date: work_date,
                          tax_client_id: 1, client_name: "Acme", hours: 8, approval_state: "approved")
    end
  end

  def report(from, through)
    ClientProfitability::Report.new(organization: organization, settings: settings.reload,
                                    period: ClientProfitability::Period.parse(from, through)).call
  end

  it "counts each paycheck whole in the month it was paid by default, matching the Annual Payroll Summary" do
    november = report("2026-11", "2026-11")
    expect(november.dig(:options, :cost_basis)).to eq("pay_date")
    expect(november[:totals]).to include(cost: "1500.00")
    expect(november[:cost_basis]).to eq(basis: "pay_date", cost: "1500.00", annual_payroll_summary_cost: "1500.00", difference: "0.00")
    expect(report("2026-12", "2026-12")[:totals]).to include(cost: "3000.00")
  end

  it "spreads a paycheck over the days it covers when counting by work period" do
    settings.update!(cost_basis: "work_period")

    november = report("2026-11", "2026-11")
    expect(november[:totals]).to include(cost: "3000.00") # 1,500 + 15/30 of 3,000
    expect(november[:cost_basis]).to eq(basis: "work_period", cost: "3000.00", annual_payroll_summary_cost: "1500.00", difference: "1500.00")
    december = report("2026-12", "2026-12")
    expect(december[:totals]).to include(cost: "1500.00")
    expect(december[:cost_basis]).to include(annual_payroll_summary_cost: "3000.00", difference: "-1500.00")
    expect(december.dig(:clients, 0)).to include(name: "Acme Bakery", cost: "1500.00") # allocation by hours is unchanged
  end

  it "reconciles with the Annual Payroll Summary over a range that covers every worked day" do
    both = report("2026-11", "2026-12")
    expect(both[:cost_basis]).to include(cost: "4500.00", difference: "0.00")
    settings.update!(cost_basis: "work_period")
    expect(report("2026-11", "2026-12")[:cost_basis]).to include(cost: "4500.00", annual_payroll_summary_cost: "4500.00", difference: "0.00")
  end

  it "labels the basis in the CSV" do
    csv = CSV.parse(ClientProfitability::CsvExport.new(report("2026-11", "2026-11")).generate)
    expect(csv).to include([ "Count pay by", "Pay date (matches the Annual Payroll Summary)" ])
    settings.update!(cost_basis: "work_period")
    csv = CSV.parse(ClientProfitability::CsvExport.new(report("2026-11", "2026-11")).generate)
    expect(csv).to include([ "Count pay by", "Work period (each paycheck spread over the days it covers)" ])
  end

  it "rejects an unknown basis or default period" do
    expect(settings.tap { |record| record.cost_basis = "accrual" }).not_to be_valid
    expect(settings.reload.tap { |record| record.default_period = "year" }).not_to be_valid
  end
end

# Edge cases for the work-period basis, at the AnnualPayrollSummary level.
RSpec.describe AnnualPayrollSummary, "#payroll_cost_by_employee with basis: :work_period" do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:user) { create(:user, company: company, role: "admin") }

  def cost(from, through, basis: :work_period)
    described_class.new(company: company).payroll_cost_by_employee(
      PayrollReportingPeriod.new(start_date: Date.parse(from), end_date: Date.parse(through)), basis: basis
    )
  end

  def total(from, through, basis: :work_period)
    cost(from, through, basis: basis)[:total_payroll_cost]
  end

  def check(first, last, paid, gross, **attributes)
    period = create(:pay_period, :committed, company: company, start_date: Date.parse(first), end_date: Date.parse(last), pay_date: Date.parse(paid))
    create(:payroll_item, company: company, employee: employee, pay_period: period, gross_pay: gross, **attributes)
  end

  def imported(first, last, paid, gross, employee: self.employee)
    batch = create(:historical_import_batch, company: company, status: "locked")
    batch.update_columns(locked_at: Time.current, locked_by_id: user.id)
    period = HistoricalPayPeriod.create!(historical_import_batch: batch, company: company, external_key: "period-#{batch.id}",
                                         source_label: "Imported", start_date: Date.parse(first), end_date: Date.parse(last),
                                         pay_date: Date.parse(paid), period_type: "regular", paycheck_count: 1, totals: {})
    worker = create(:historical_worker, historical_import_batch: batch, company: company, employee: employee,
                                        external_key: "worker-#{batch.id}", mapping_status: employee ? "exact_match" : "archive_only")
    HistoricalPaycheck.create!(
      historical_import_batch: batch, historical_pay_period: period, historical_worker: worker, company: company, employee: employee,
      external_key: "paycheck-#{batch.id}", source_employee_name: "Imported Worker", source_row_number: 1, source_status: "paid",
      reconciliation_status: employee ? "matched" : "unmatched", period_start: period.start_date, period_end: period.end_date,
      pay_date: period.pay_date, hours_total: 40, gross_pay: gross, adjusted_gross: gross, pretax_deductions: 0, employee_taxes: 0,
      federal_income_tax: 0, social_security_tax: 0, medicare_tax: 0, after_tax_deductions: 0, net_pay: 1, employer_taxes: 0,
      employer_contributions: 0, total_payroll_cost: gross
    )
  end

  it "counts pay in the months worked, however late it was paid" do
    check("2026-11-01", "2026-11-30", "2027-05-01", "1000.00")
    expect(total("2026-11-01", "2026-11-30")).to eq(1000)
    expect(total("2027-05-01", "2027-05-31")).to eq(0)
    expect(total("2026-11-01", "2027-05-31")).to eq(1000)
    expect(total("2027-05-01", "2027-05-31", basis: :pay_date)).to eq(1000)
  end

  it "splits whole cents so months always add up to the range, and the parts add up to each row" do
    check("2026-11-30", "2026-12-01", "2026-12-05", "100.01", employer_social_security_tax: "7.65")
    november = cost("2026-11-01", "2026-11-30")[:by_employee].fetch(employee.id)
    december = cost("2026-12-01", "2026-12-31")[:by_employee].fetch(employee.id)
    expect(november).to eq(pay: BigDecimal("50.00"), employer_taxes: BigDecimal("3.82"), employer_contributions: 0, total: BigDecimal("53.82"))
    expect(december).to eq(pay: BigDecimal("50.01"), employer_taxes: BigDecimal("3.83"), employer_contributions: 0, total: BigDecimal("53.84"))
    expect(november[:total] + december[:total]).to eq(total("2026-11-01", "2026-12-31"))
    expect(total("2026-11-01", "2026-12-31")).to eq(BigDecimal("107.66"))
  end

  it "splits a paycheck across the year boundary" do
    check("2026-12-16", "2027-01-15", "2027-01-20", "3100.01")
    december = total("2026-12-01", "2026-12-31")
    january = total("2027-01-01", "2027-01-31")
    expect([ december, january ]).to eq([ BigDecimal("1600.00"), BigDecimal("1500.01") ])
    expect(december + january).to eq(BigDecimal("3100.01"))
    expect(total("2026-01-01", "2026-12-31", basis: :pay_date)).to eq(0)
  end

  it "spreads imported paychecks and their adjustments over the imported pay period" do
    paycheck = imported("2026-10-26", "2026-11-08", "2026-11-13", "1400.00")
    HistoricalPaycheckAdjustment.create!(
      company: company, historical_paycheck: paycheck, created_by: user, kind: "correction", effective_pay_date: paycheck.pay_date,
      filing_year: 2026, filing_quarter: 4, reason: "Correct source evidence after review", idempotency_key: "work-period-adjustment",
      hours_total: 0, gross_pay: 140, adjusted_gross: 140, pretax_deductions: 0, employee_taxes: 0, federal_income_tax: 0,
      after_tax_deductions: 0, net_pay: 140, employer_taxes: 0, employer_contributions: 0, total_payroll_cost: 140
    )
    imported("2026-10-26", "2026-11-08", "2026-11-13", "700.00", employee: nil) # no employee: shown apart, never counted

    october = cost("2026-10-01", "2026-10-31")
    november = cost("2026-11-01", "2026-11-30")
    expect(october[:total_payroll_cost]).to eq(BigDecimal("660.00")) # 6 of 14 days of 1,400 + 140
    expect(november[:total_payroll_cost]).to eq(BigDecimal("880.00"))
    expect(october[:total_payroll_cost] + november[:total_payroll_cost]).to eq(1540)
    expect(october[:excluded_unlinked]).to eq(paycheck_count: 1, total_payroll_cost: BigDecimal("300.00"))
    # By pay date, the paycheck and its adjustment both land in November.
    expect(total("2026-11-01", "2026-11-30", basis: :pay_date)).to eq(1540)
    expect(total("2026-10-01", "2026-10-31", basis: :pay_date)).to eq(0)
  end

  it "keeps voided runs and reversed paychecks out, and spreads corrections like any run" do
    original = check("2026-11-01", "2026-11-14", "2026-11-20", "1400.00")
    original.pay_period.update_columns(correction_status: "voided", voided_at: Time.current, void_reason: "Wrong hours")
    correction = check("2026-11-01", "2026-11-14", "2026-12-04", "1120.00")
    correction.pay_period.update_columns(correction_status: "correction", source_pay_period_id: original.pay_period_id)
    reversed = check("2026-11-15", "2026-11-28", "2026-12-04", "999.00")
    reversed.update_columns(payroll_reversed_at: Time.current, payroll_reversed_by_id: user.id, payroll_reversal_reason: "Issued in error")

    expect(total("2026-11-01", "2026-11-30")).to eq(1120)
    expect(total("2026-11-01", "2026-11-30", basis: :pay_date)).to eq(0)
    expect(total("2026-12-01", "2026-12-31", basis: :pay_date)).to eq(1120)
  end

  it "spreads an off-cycle run over its own short period" do
    bonus = check("2026-11-30", "2026-12-01", "2026-12-01", "500.01")
    bonus.pay_period.update_columns(cycle: "supplemental", run_purpose: "bonus")
    expect(total("2026-11-01", "2026-11-30")).to eq(BigDecimal("250.00"))
    expect(total("2026-12-01", "2026-12-31")).to eq(BigDecimal("250.01"))
    expect(total("2026-12-01", "2026-12-31", basis: :pay_date)).to eq(BigDecimal("500.01"))
  end

  it "falls back to the pay date when a pay period has no usable dates" do
    summary = described_class.new(company: company)
    november = PayrollReportingPeriod.new(start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 30))
    expect(summary.send(:cents_in_range, "100.00", nil, nil, Date.new(2026, 11, 20), november)).to eq(10_000)
    expect(summary.send(:cents_in_range, "100.00", nil, Date.new(2026, 10, 1), Date.new(2026, 10, 5), november)).to eq(0)
    expect(summary.send(:cents_in_range, "100.00", Date.new(2026, 11, 10), Date.new(2026, 11, 1), Date.new(2026, 11, 20), november)).to eq(10_000)
    expect(summary.send(:cents_in_range, "-100.01", Date.new(2026, 11, 30), Date.new(2026, 12, 1), Date.new(2026, 12, 5), november)).to eq(-5000)
  end
end
