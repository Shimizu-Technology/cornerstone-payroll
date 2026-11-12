# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Pay-period catalog and change rows" do
  include ActiveSupport::Testing::TimeHelpers
  let(:company) { create(:company) }

  def schedule!(attrs)
    CompanyPaySchedule.create!({ company: company, timezone: "Pacific/Guam", source: "operator_confirmed",
      confirmation_status: "needs_confirmation" }.merge(attrs))
  end

  it "keeps the preceding schedule's periods offered after a schedule change" do
    schedule!(frequency: "weekly", period_rule: "manual", pay_date_rule: "manual", effective_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 11, 15))
    schedule!(frequency: "semimonthly", period_rule: "semimonthly", pay_date_rule: "semimonthly_15th_and_month_end", effective_on: Date.new(2026, 11, 16))
    create(:pay_period, company: company, start_date: Date.new(2026, 11, 9), end_date: Date.new(2026, 11, 15), pay_date: Date.new(2026, 11, 20))
    catalog = PayrollSubmissions::Catalog.new(company: company, today: Date.new(2026, 11, 18))
    refs = catalog.entries.map(&:ref)
    expect(refs).to include("2026-11-16_2026-11-30", "2026-11-09_2026-11-15")
    expect(refs).not_to include("2026-11-01_2026-11-15")
    entry = catalog.resolve("2026-11-09_2026-11-15")
    expect(entry.pay_period).to be_present
    expect(catalog.open_for_files?(entry)).to be(true)
  end

  it "also keeps derived periods of a preceding anchored schedule, without duplicates" do
    schedule!(frequency: "biweekly", period_rule: "biweekly", period_start_weekday: 1, period_anchor_date: Date.new(2026, 10, 19),
      pay_date_rule: "manual", effective_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 11, 15))
    schedule!(frequency: "semimonthly", period_rule: "semimonthly", pay_date_rule: "semimonthly_15th_and_month_end", effective_on: Date.new(2026, 11, 16))
    create(:pay_period, company: company, start_date: Date.new(2026, 11, 2), end_date: Date.new(2026, 11, 15), pay_date: Date.new(2026, 11, 20))
    refs = PayrollSubmissions::Catalog.new(company: company, today: Date.new(2026, 11, 18)).entries.map(&:ref)
    expect(refs.count("2026-11-02_2026-11-15")).to eq(1)
    expect(refs).to include("2026-10-19_2026-11-01")
  end

  it "opens files on the schedule's local date, not Guam's" do
    schedule!(frequency: "biweekly", period_rule: "manual", pay_date_rule: "manual", timezone: "Pacific/Honolulu", effective_on: Date.new(2026, 1, 1))
    create(:pay_period, company: company, start_date: Date.new(2026, 11, 2), end_date: Date.new(2026, 11, 15), pay_date: Date.new(2026, 11, 20))
    travel_to(Time.utc(2026, 11, 15, 2, 0)) do # Nov 15 noon in Guam, Nov 14 4 PM in Honolulu
      catalog = PayrollSubmissions::Catalog.new(company: company)
      expect(catalog.open_for_files?(catalog.resolve("2026-11-02_2026-11-15"))).to be(false)
    end
    travel_to(Time.utc(2026, 11, 15, 12, 0)) do
      catalog = PayrollSubmissions::Catalog.new(company: company)
      expect(catalog.open_for_files?(catalog.resolve("2026-11-02_2026-11-15"))).to be(true)
    end
  end

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
