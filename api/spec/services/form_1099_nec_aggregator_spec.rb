# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form1099NecAggregator, type: :service do
  let(:company) { create(:company) }
  let(:pay_period) { create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 5, 15)) }
  let(:voided_pay_period) { create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 5, 30)) }
  let(:contractor) { create(:employee, :contractor, company: company, first_name: "Asia", last_name: "Taylor") }
  let!(:threshold_rule) do
    InformationReturnThreshold.find_or_initialize_by(form_type: "1099_nec", tax_year: 2026).tap do |rule|
      rule.update!(threshold_amount: 2_000, source_url: "https://www.irs.gov/instructions/i1099mec", effective_on: Date.new(2026, 1, 1))
    end
  end

  it "excludes voided contractor payments from 1099 compensation" do
    create(:payroll_item,
      pay_period: pay_period,
      employee: contractor,
      company: company,
      employment_type: "contractor",
      gross_pay: 500.00,
      net_pay: 500.00,
      withholding_tax: 0.00
    )
    create(:payroll_item, :voided,
      pay_period: voided_pay_period,
      employee: contractor,
      company: company,
      employment_type: "contractor",
      gross_pay: 175.00,
      net_pay: 175.00,
      withholding_tax: 0.00
    )

    report = described_class.new(company, 2026).generate
    asia = report[:all_contractors].find { |row| row[:employee_id] == contractor.id }

    expect(asia[:total_compensation]).to eq(500.00)
    expect(asia[:payment_count]).to eq(1)
    expect(asia[:requires_filing]).to eq(false)
    expect(report[:meta][:filing_threshold]).to eq(2_000.0)
    expect(report[:meta][:filing_threshold_rule_id]).to eq(threshold_rule.id)
    expect(report[:totals][:total_compensation]).to eq(500.00)
  end


  it "uses the prior-year threshold without changing the 2026 rule" do
    InformationReturnThreshold.find_or_initialize_by(form_type: "1099_nec", tax_year: 2025).tap do |rule|
      rule.update!(threshold_amount: 600, source_url: "https://www.irs.gov/instructions/i1099mec", effective_on: Date.new(2025, 1, 1))
    end
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2025, 5, 15))
    create(:payroll_item,
      pay_period: prior_period,
      employee: contractor,
      company: company,
      employment_type: "contractor",
      gross_pay: 700.00,
      net_pay: 700.00)

    report = described_class.new(company, 2025).generate

    expect(report[:meta][:filing_threshold]).to eq(600.0)
    expect(report[:meta][:reportable_count]).to eq(1)
  end

  it "uses the historical payroll-item classification after the worker is W-2" do
    transitioned_worker = create(:employee, company: company, first_name: "Legacy", last_name: "Worker")
    create(:payroll_item,
      pay_period: pay_period,
      employee: transitioned_worker,
      company: company,
      employment_type: "contractor",
      gross_pay: 275.00,
      net_pay: 275.00)

    row = described_class.new(company, 2026).generate[:all_contractors].sole

    expect(row[:employee_id]).to eq(transitioned_worker.id)
    expect(row[:total_compensation]).to eq(275.00)
  end
end
