# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFilingSourceSnapshot do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company) }
  let(:period) do
    create(
      :pay_period,
      :committed,
      company: company,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 15),
      pay_date: Date.new(2026, 4, 20),
      committed_by_id: actor.id
    )
  end
  let!(:item) do
    create(
      :payroll_item,
      company: company,
      pay_period: period,
      employee: employee,
      gross_pay: 1_000,
      total_deductions: 200,
      net_pay: 800,
      check_number: "4200"
    )
  end

  it "changes only for filing-source payroll data, not later check delivery evidence" do
    initial = described_class.new(company: company, tax_year: 2026, quarter: 2).call

    item.check_events.create!(
      user: actor,
      event_type: "printed",
      check_number: item.check_number,
      effective_on: Date.new(2026, 4, 20)
    )

    after_printing = described_class.new(company: company, tax_year: 2026, quarter: 2).call

    expect(after_printing.fingerprint).to eq(initial.fingerprint)
    expect(after_printing.snapshot).to eq(initial.snapshot)
  end
end
