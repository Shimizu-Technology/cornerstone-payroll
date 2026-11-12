# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Pay-period catalog and change rows" do
  let(:company) { create(:company) }

  it "derives semimonthly periods from the schedule without an anchor" do
    CompanyPaySchedule.create!(company: company, frequency: "semimonthly", period_rule: "semimonthly",
      pay_date_rule: "semimonthly_15th_and_month_end", timezone: "Pacific/Guam", source: "operator_confirmed",
      confirmation_status: "needs_confirmation", effective_on: Date.new(2026, 1, 1))
    catalog = PayrollSubmissions::Catalog.new(company: company, today: Date.new(2026, 11, 17))
    expect(catalog.derives_from_schedule?).to be(true)
    entries = catalog.entries
    expect(entries.first(3).map { |e| [ e.start_date.iso8601, e.end_date.iso8601 ] }).to eq([
      %w[2026-11-16 2026-11-30], %w[2026-11-01 2026-11-15], %w[2026-10-16 2026-10-31]
    ])
    expect(entries.second.pay_date).to eq(Date.new(2026, 11, 30))
    expect(catalog.open_for_files?(entries.first)).to be(false)
    expect(catalog.resolve("2026-11-01_2026-11-15")).to be_present
    expect(catalog.resolve("2026-11-02_2026-11-15")).to be_nil
    expect(catalog.resolve("2026-02-31_2026-03-01")).to be_nil
  end

  it "offers nothing when the company has neither a derivable schedule nor created periods" do
    expect(PayrollSubmissions::Catalog.new(company: company, today: Date.new(2026, 11, 17)).entries).to eq([])
  end

  it "labels periods across months and years" do
    expect(PayrollSubmissions::PeriodLabel.call(Date.new(2026, 10, 19), Date.new(2026, 11, 1))).to eq("Oct 19 – Nov 1, 2026")
    expect(PayrollSubmissions::PeriodLabel.call(Date.new(2026, 12, 28), Date.new(2027, 1, 10))).to eq("Dec 28, 2026 – Jan 10, 2027")
  end

  it "normalizes rows and reports every invalid field" do
    employee = create(:employee, company: company)
    rows = PayrollSubmissions::ChangeRows.normalize!([
      { "kind" => "owner_pay", "amount" => "2400.00", "basis" => "total", "employee_ids" => [ employee.id.to_s ] },
      { "kind" => "deduction", "employee_id" => employee.id, "deduction_action" => "stop", "description" => "Uniform" }
    ], company_id: company.id)
    expect(rows).to eq([
      { "kind" => "owner_pay", "employee_ids" => [ employee.id ], "amount" => "2400.00", "basis" => "total" },
      { "kind" => "deduction", "employee_id" => employee.id, "deduction_action" => "stop", "description" => "Uniform" }
    ])
    expect do
      PayrollSubmissions::ChangeRows.normalize!([
        { "kind" => "owner_pay", "amount" => "-5" },
        { "kind" => "routing_number", "value" => "x" },
        { "kind" => "wage_change", "employee_id" => employee.id, "new_wage" => "1e9", "wage_unit" => "weekly" }
      ], company_id: company.id)
    end.to raise_error(PayrollSubmissions::ChangeRows::Invalid) { |error|
      expect(error.details.keys).to eq(%w[changes.1 changes.2 changes.3])
      expect(error.details["changes.1"].join).to include("total or for each owner")
    }
  end
end
