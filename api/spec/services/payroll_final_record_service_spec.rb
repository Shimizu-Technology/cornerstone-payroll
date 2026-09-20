# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFinalRecordService do
  let(:company) { create(:company, client_payroll_approval_required: true) }
  let(:employee) { create(:employee, company:, first_name: "Mo", last_name: "Shimizu") }
  let(:period) do
    create(:pay_period, :committed, company:, start_date: Date.new(2026, 8, 1),
      end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 20))
  end
  let!(:item) do
    create(:payroll_item, company:, pay_period: period, employee:,
      gross_pay: 1_000, non_taxable_pay: 25, total_deductions: 350, net_pay: 675,
      withholding_tax: 100, social_security_tax: 62, medicare_tax: 14.5,
      additional_withholding: 23.5, tips_paid_out: 50, loan_deduction: 25, loan_payment: 25,
      employer_social_security_tax: 62, employer_medicare_tax: 14.5,
      employer_retirement_match: 40, check_number: "8200")
  end

  before do
    PayrollLiabilityPostingService.post!(pay_period: period)
  end

  it "builds a balanced, exact-money record from committed values" do
    result = described_class.new(pay_period: period).call

    expect(result.dig(:official_payroll, :total_payroll_cost)).to eq("1141.5")
    expect(result[:journal]).to include(
      debit_total: "1141.5",
      credit_total: "1141.5",
      difference: "0.0",
      balanced: true
    )
    expect(result.dig(:journal, :lines).index_by { |line| line[:account_key] }).to include(
      "employee_tax_payable" => include(credit: "200.0"),
      "employee_deduction_payable" => include(credit: "75.0"),
      "employee_loan_receivable" => include(credit: "25.0"),
      "tips_paid_clearing" => include(credit: "50.0")
    )
    expect(result.dig(:employee_payments, :rows, 0)).to include(
      employee_name: "Mo Shimizu", amount: "675.0", check_number: "8200"
    )
    expect(result[:record_fingerprint]).to match(/\A[0-9a-f]{64}\z/)
  end

  it "records direct and separately itemized loans in the same loan journal category" do
    type = DeductionType.create!(company: company, name: "Loan - Madela Severin",
      category: "post_tax", sub_category: "loan", active: true)
    item.payroll_item_deductions.create!(deduction_type: type, category: "post_tax", amount: BigDecimal("250"),
      label: type.name)
    item.update!(loan_deduction: BigDecimal("428.36"), loan_payment: BigDecimal("678.36"),
      total_deductions: BigDecimal("1003.36"), net_pay: BigDecimal("21.64"))

    journal = described_class.new(pay_period: period).call.fetch(:journal)
    expect(journal.fetch(:lines).index_by { |line| line[:account_key] }).to include(
      "employee_loan_receivable" => include(credit: "678.36")
    )
    expect(journal).to include(balanced: true, difference: "0.0")
  end

  it "distinguishes blocking record gaps from open settlement work" do
    result = described_class.new(pay_period: period).call

    expect(result.dig(:completion, :status)).to eq("attention_required")
    expect(result.dig(:completion, :blockers)).to include("The required client-approved payroll review evidence is missing")
    expect(result.dig(:completion, :open_items)).to include(
      "Reconcile 1 employee check",
      "Settle $316.50 in payroll liabilities"
    )
    expect(result.dig(:liabilities, :payment_tracking_status)).to eq("tracked_in_liability_center")
  end

  it "treats direct deposit as a payment record, not a missing paper check" do
    item.update!(check_number: nil, payment_delivery_method: "direct_deposit")

    result = described_class.new(pay_period: period).call

    expect(result[:employee_payments]).to include(
      required_count: 0,
      direct_deposit_count: 1,
      assigned_count: 0,
      outstanding_count: 0
    )
    expect(result.dig(:employee_payments, :rows, 0)).to include(
      payment_delivery_method: "direct_deposit",
      issuance_status: "transfer_not_confirmed",
      reconciliation_status: "not_confirmed"
    )
    expect(result.dig(:completion, :blockers).join).not_to include("check number")
    expect(result.dig(:completion, :open_items).join).not_to include("employee check")
    expect(result.dig(:completion, :open_items)).to include("Confirm 1 direct-deposit payment with bank evidence")
  end

  it "shows confirmed bank payment as settled in the final payroll record" do
    item.update!(check_number: nil, payment_delivery_method: "direct_deposit")
    actor = create(:user, company: company, organization: company.organization)
    item.create_direct_deposit_payment_confirmation!(
      user: actor, settled_on: PayrollBusinessClock.today, bank_reference: "BANK-TEST-8200"
    )

    result = described_class.new(pay_period: period).call

    expect(result.dig(:employee_payments, :rows, 0)).to include(
      issuance_status: "bank_confirmed", reconciliation_status: "bank_confirmed"
    )
    expect(result.dig(:completion, :open_items).join).not_to include("direct-deposit")
  end

  it "rejects a draft because it is not an official payroll record" do
    period.update!(status: "draft", committed_at: nil)

    expect { described_class.new(pay_period: period).call }
      .to raise_error(described_class::Error, /available after payroll is committed/)
  end
end
