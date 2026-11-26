# frozen_string_literal: true

require "rails_helper"

# Full-year date-range reports take bridged employees' figures from their
# opening balances. Finding which imported rows each balance covers must not
# cost queries per employee.
RSpec.describe UnifiedPayrollReporting, "bridge coverage" do
  let(:company) { create(:company) }
  let(:batch) { create(:historical_import_batch, company: company, status: "locked") }
  let(:bridge) do
    HistoricalYtdBridge.create!(
      company: company, historical_import_batch: batch,
      historical_client_bootstrap: create(:historical_client_bootstrap, company: company, historical_import_batch: batch, status: "applied"),
      status: "applied", plan_digest: SecureRandom.hex(16), applied_at: Time.current, applied_by: create(:user, company: company),
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT,
      preview_summary: { "through_period_end" => "2026-01-14", "through_pay_date" => "2026-01-20",
                         "adjustment_digest" => HistoricalPayroll::Ledger.new(batch: batch).adjustment_digest }
    )
  end
  let(:period) { PayrollReportingPeriod.new(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 12, 31)) }

  def bridged_employee
    employee = create(:employee, company: company)
    paycheck = create(:historical_paycheck, employee: employee, company: company, historical_import_batch: batch,
      gross_pay: 1_000, net_pay: 800, federal_income_tax: 100)
    HistoricalEmployeeYtdBalance.create!(historical_ytd_bridge: bridge, company: company, employee: employee, tax_year: 2026,
      through_pay_date: Date.new(2026, 1, 20), through_period_end: Date.new(2026, 1, 14),
      gross_pay: 1_000, net_pay: 800, federal_income_tax: 112.34, source_breakdown: {})
    [ employee, paycheck ]
  end

  def rows_and_queries(count)
    pairs = Array.new(count) { bridged_employee }
    paychecks = HistoricalPaycheck.includes(:historical_import_batch, :historical_pay_period).where(id: pairs.map(&:last)).order(:id).to_a
    reporting = described_class.new(company_id: company.id, period: period)
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:cached] }
    rows = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      paychecks.map { |paycheck| reporting.add_historical_to_employee_row({}, [ paycheck ], []) }
    end
    [ rows, queries ]
  end

  it "takes each employee's money figures from the balance, labelling which fields" do
    rows, = rows_and_queries(2)
    expect(rows.map { |row| row[:withholding_tax] }).to all(eq(112.34.to_d))
    expect(rows.map { |row| row[:imported_basis] }).to all(eq(UnifiedPayrollReporting::BRIDGED))
    expect(rows.first[:bridged_fields]).to eq(UnifiedPayrollReporting::BRIDGE_FIGURES.keys.map(&:to_s))
  end

  it "loads balance coverage in the same number of queries for two or eight bridged employees" do
    _, two = rows_and_queries(2)
    _, eight = rows_and_queries(8)
    expect(eight).to eq(two)
  end
end
