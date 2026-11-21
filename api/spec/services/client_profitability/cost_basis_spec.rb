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
