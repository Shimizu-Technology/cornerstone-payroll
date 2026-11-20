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

  it "excludes financially reversed contractor payroll from 1099 compensation" do
    create(:payroll_item,
      pay_period: pay_period,
      employee: contractor,
      company: company,
      employment_type: "contractor",
      gross_pay: 500.00,
      net_pay: 500.00,
      withholding_tax: 0.00
    )
    create(:payroll_item, :voided, **payroll_reversal_fixture,
      pay_period: voided_pay_period,
      employee: contractor,
      company: company,
      employment_type: "contractor",
      gross_pay: 175.00,
      net_pay: 175.00,
      withholding_tax: 0.00
    )

    create(:payroll_item, :voided, pay_period: create(:pay_period, :committed, company: company, pay_date: pay_period.pay_date), employee: contractor, company: company,
      employment_type: "contractor", gross_pay: 225, net_pay: 225, withholding_tax: 0)
    report = described_class.new(company, 2026).generate
    asia = report[:all_contractors].find { |row| row[:employee_id] == contractor.id }

    expect(asia[:total_compensation]).to eq(725.00)
    expect(asia[:payment_count]).to eq(2)
    expect(asia[:requires_filing]).to eq(false)
    expect(report[:meta][:filing_threshold]).to eq(2_000.0)
    expect(report[:meta][:filing_threshold_rule_id]).to eq(threshold_rule.id)
    expect(report[:totals][:total_compensation]).to eq(725.00)
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
  it "includes active one-off checks by payment year, groups repeated payees, and excludes voids and superseded checks" do
    first = create(:non_employee_check, company: company, check_type: "contractor", payable_to: "Synthetic Vendor", amount: 300, printed_at: Time.current)
    second = create(:non_employee_check, company: company, check_type: "contractor", payable_to: first.payable_to, amount: 297.50, printed_at: Time.current)
    create(:non_employee_check, company: company, check_type: "contractor", payable_to: first.payable_to, amount: 700)
    create(:non_employee_check, company: company, check_type: "contractor", payable_to: first.payable_to, amount: 900,
      voided: true, voided_at: Time.current, void_reason: "Destroyed")
    create(:non_employee_check, company: company, check_type: "vendor", amount: 2000)
    create(:non_employee_check, company: create(:company), check_type: "contractor", amount: 2000)
    create(:non_employee_check, company: company, check_type: "contractor", payment_date: Date.new(2025, 12, 31), amount: 2000, printed_at: Time.current)
    actor = create(:user, company: company)
    CheckSupersessionRolloutApproval.create!(company: company, approved_by: create(:user, company: company, role: "org_admin"),
      reason: "Approved for isolated reconciliation test only", approved_at: Time.current)
    payroll = create(:payroll_item, :printed, company: company, employee: contractor, pay_period: pay_period,
      employment_type: "contractor", gross_pay: 2100, net_pay: 2100, check_number: "777", payment_delivery_method: "paper_check")
    create(:check_event, payroll_item: payroll, user: actor, event_type: "delivered", effective_on: PayrollBusinessClock.today)
    superseded = create(:non_employee_check, company: company, check_type: "contractor", payable_to: contractor.full_name,
      amount: 2100, check_number: "777", printed_at: Time.current)
    NonEmployeeCheckSupersessionService.new(check: superseded, actor: actor).supersede!(payroll_item_id: payroll.id,
      reason: "Same physical contractor check verified against payroll", recipient_verified: true)

    report = described_class.new(company, 2026).generate
    check_row = report[:all_contractors].find { |row| row[:employee_id].nil? }
    expect(check_row).to include(total_compensation: 597.50, payment_count: 2, requires_filing: false,
      non_employee_check_ids: [ first.id, second.id ])
    expect(check_row[:compliance_issues]).to include(/no worker\/TIN link/)
    expect(report[:totals]).to include(total_compensation: 2697.50, reportable_compensation: 2100)
    expect(report.dig(:meta, :caveats).join).to include("1 contractor check(s) dated 2026 are not printed or paid yet")
  end

  it "uses the year-specific threshold for one-off check recipients and the linked pay date fallback" do
    create(:information_return_threshold, tax_year: 2025, threshold_amount: 600)
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2025, 12, 31))
    create(:non_employee_check, company: company, check_type: "contractor", pay_period: prior_period, payment_date: nil, amount: 600, printed_at: Time.current)
    create(:non_employee_check, company: company, check_type: "contractor", payment_date: Date.new(2026, 1, 1), amount: 2000, printed_at: Time.current)
    expect(described_class.new(company, 2025).generate[:reportable_contractors].sole[:total_compensation]).to eq(600)
    expect(described_class.new(company, 2026).generate[:reportable_contractors].sole[:total_compensation]).to eq(2000)
  end
  [ 0, 12.34 ].each do |withheld|
    it "reports $1,500 only when tax was withheld (#{withheld}) and serializes decimal totals" do
      create(:payroll_item, company: company, employee: contractor, pay_period: pay_period,
        employment_type: "contractor", gross_pay: 1500, net_pay: 1500 - withheld, withholding_tax: withheld)
      report = described_class.new(company, 2026).generate
      expect(report[:meta][:reportable_count]).to eq(withheld.zero? ? 0 : 1)
      expect(report[:all_contractors].sole[:requires_filing]).to eq(!withheld.zero?)
      expect(report[:all_contractors].sole[:filing_reason]).to eq("tax withheld") unless withheld.zero?
      total = report[:totals][:reportable_federal_withheld]
      expect(total).to be_a(BigDecimal)
      expect(JSON.parse(report.to_json).dig("totals", "reportable_federal_withheld").to_d).to eq(withheld.to_d)
    end
  end
end
