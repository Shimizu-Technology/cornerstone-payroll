# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollLiabilitySettlementService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company:, organization: company.organization) }
  let(:department) { create(:department, company:) }
  let(:employee) { create(:employee, company:, department:) }
  let(:pay_period) do
    create(:pay_period, :committed, company:,
      start_date: Date.new(2026, 6, 29),
      end_date: Date.new(2026, 7, 12),
      pay_date: Date.new(2026, 7, 15))
  end
  let!(:payroll_item) do
    create(:payroll_item,
      pay_period:,
      employee:,
      company:,
      gross_pay: 2_000,
      net_pay: 1_465,
      withholding_tax: 150,
      additional_withholding: 25,
      social_security_tax: 124,
      employer_social_security_tax: 124,
      medicare_tax: 29,
      employer_medicare_tax: 29)
  end

  before do
    PayrollLiabilityPostingService.post!(pay_period:, actor:)
  end

  it "records and exactly allocates a partial payment without changing payroll" do
    payroll_snapshot = payroll_item.attributes

    payment = described_class.record!(
      pay_period:,
      actor:,
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      category: "guam_income_tax_withheld",
      amount: "100.00",
      payment_date: "2026-07-20",
      payment_method: "ach",
      confirmation_number: "DRT-100",
      idempotency_key: "phase-1b-partial"
    )

    expect(payment).to have_attributes(
      amount: 100.00,
      payment_type: "settlement",
      confirmation_number: "DRT-100"
    )
    expect(payment.allocations.sum(:amount)).to eq(100.00)
    expect(payment.allocations.map(&:payroll_liability_entry).uniq).to all(
      have_attributes(authority: PayrollLiabilityPostingService::GUAM_DRT, category: "guam_income_tax_withheld")
    )
    expect(payroll_item.reload.attributes).to eq(payroll_snapshot)

    reconciliation = PayrollLiabilityReconciliationService.new(pay_period:).call
    obligation = reconciliation.fetch(:obligations).find do |row|
      row[:authority] == PayrollLiabilityPostingService::GUAM_DRT && row[:category] == "guam_income_tax_withheld"
    end
    expect(obligation).to include(
      calculated_amount: 175.0,
      settled_amount: 100.0,
      outstanding_amount: 75.0,
      status: "partially_paid"
    )
  end

  it "is idempotent and rejects cross-payroll idempotency-key reuse" do
    attributes = {
      pay_period:,
      actor:,
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      category: "guam_income_tax_withheld",
      amount: 25,
      payment_date: "2026-07-20",
      payment_method: "check",
      idempotency_key: "phase-1b-idempotent"
    }

    first = described_class.record!(**attributes)
    expect(described_class.record!(**attributes).id).to eq(first.id)
    expect(PayrollLiabilityPayment.where(idempotency_key: "phase-1b-idempotent").count).to eq(1)

    other_period = create(:pay_period, :committed, company:)
    expect {
      described_class.record!(**attributes.merge(pay_period: other_period))
    }.to raise_error(described_class::InvalidStateError, /another payroll/)
  end

  it "allows separate companies to use the same idempotency key without revealing each other's payments" do
    other_company = create(:company)
    other_actor = create(:user, company: other_company, organization: other_company.organization)
    other_department = create(:department, company: other_company)
    other_employee = create(:employee, company: other_company, department: other_department)
    other_period = create(:pay_period, :committed, company: other_company)
    create(:payroll_item,
      pay_period: other_period,
      employee: other_employee,
      company: other_company,
      withholding_tax: 50)
    PayrollLiabilityPostingService.post!(pay_period: other_period, actor: other_actor)

    shared_key = "tenant-scoped-payment-key"
    other_payment = described_class.record!(
      pay_period: other_period,
      actor: other_actor,
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      category: "guam_income_tax_withheld",
      amount: 25,
      payment_date: "2026-07-20",
      payment_method: "ach",
      idempotency_key: shared_key
    )
    payment = described_class.record!(
      pay_period:,
      actor:,
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      category: "guam_income_tax_withheld",
      amount: 25,
      payment_date: "2026-07-20",
      payment_method: "ach",
      idempotency_key: shared_key
    )

    expect(payment.company_id).to eq(company.id)
    expect(other_payment.company_id).to eq(other_company.id)
    expect(PayrollLiabilityPayment.where(idempotency_key: shared_key).pluck(:company_id))
      .to contain_exactly(company.id, other_company.id)
  end

  it "rejects overpayment after netting signed credits in the obligation group" do
    posting = pay_period.payroll_liability_postings.find_by!(posting_type: "commit")
    posting.entries.create!(
      company:,
      payroll_item:,
      component_key: "guam_income_tax_credit",
      category: "guam_income_tax_withheld",
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      amount: -50,
      metadata: { "test_credit" => true }
    )

    expect {
      described_class.record!(
        pay_period:,
        actor:,
        authority: PayrollLiabilityPostingService::GUAM_DRT,
        category: "guam_income_tax_withheld",
        amount: 126,
        payment_date: "2026-07-20",
        payment_method: "ach"
      )
    }.to raise_error(described_class::InvalidStateError, /open liability of 125.00/)
  end

  it "creates an exact immutable reversal and restores the open balance" do
    payment = described_class.record!(
      pay_period:,
      actor:,
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      category: "guam_income_tax_withheld",
      amount: 100,
      payment_date: "2026-07-20",
      payment_method: "check"
    )

    reversal = described_class.reverse!(
      pay_period:,
      actor:,
      source_payment: payment,
      reason: "Check was voided"
    )

    expect(reversal).to have_attributes(payment_type: "reversal", amount: -100.00, source_payment_id: payment.id)
    expect(reversal.allocations.sum(:amount)).to eq(-100.00)
    expect(payment.reload.reversed?).to be(true)
    expect {
      payment.update!(notes: "mutated")
    }.to raise_error(ActiveRecord::ReadOnlyRecord)

    reconciliation = PayrollLiabilityReconciliationService.new(pay_period:).call
    expect(reconciliation).to include(settled_amount: 0.0)
  end

  it "rejects actors outside the payroll organization" do
    other_company = create(:company)
    other_actor = create(:user, company: other_company, organization: other_company.organization)

    expect {
      described_class.record!(
        pay_period:,
        actor: other_actor,
        authority: PayrollLiabilityPostingService::GUAM_DRT,
        category: "guam_income_tax_withheld",
        amount: 25,
        payment_date: "2026-07-20",
        payment_method: "ach"
      )
    }.to raise_error(described_class::InvalidStateError, /cannot record payments/)
  end

  it "keeps a real payment visible as an overpayment after payroll is voided and permits its reversal" do
    payment = described_class.record!(
      pay_period:,
      actor:,
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      category: "guam_income_tax_withheld",
      amount: 100,
      payment_date: "2026-07-20",
      payment_method: "ach"
    )
    PayrollLiabilityPostingService.reverse!(pay_period:, actor:, reason: "Payroll voided")
    pay_period.update!(correction_status: "voided", voided_at: Time.current, void_reason: "Payroll voided")

    reconciliation = PayrollLiabilityReconciliationService.new(pay_period: pay_period.reload).call
    obligation = reconciliation.fetch(:obligations).find { |row| row[:category] == "guam_income_tax_withheld" }
    expect(obligation).to include(calculated_amount: 0.0, settled_amount: 100.0, outstanding_amount: -100.0, status: "overpaid")

    reversal = described_class.reverse!(
      pay_period:,
      actor:,
      source_payment: payment,
      reason: "The transfer was also canceled"
    )
    expect(reversal.amount).to eq(-100.00)

    reconciliation = PayrollLiabilityReconciliationService.new(pay_period: pay_period.reload).call
    expect(reconciliation).to include(
      obligations: [],
      settled_amount: 0.0,
      outstanding_amount: 0.0,
      payment_tracking_status: "not_applicable"
    )
    expect(reconciliation.fetch(:payments).size).to eq(2)
  end

  it "keeps an operator due date when liability postings are restated for a corrected pay date" do
    PayrollLiabilityDueDateService.new(
      pay_period:,
      actor:,
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      category: "guam_income_tax_withheld",
      due_date: "2026-07-31"
    ).call
    old_date = pay_period.pay_date
    pay_period.update!(pay_date: Date.new(2026, 7, 20))
    PayrollLiabilityPostingService.restate_for_pay_date!(
      pay_period:,
      actor:,
      reason: "Correct pay date",
      old_pay_date: old_date,
      new_pay_date: pay_period.pay_date
    )

    reconciliation = PayrollLiabilityReconciliationService.new(pay_period: pay_period.reload).call
    obligation = reconciliation.fetch(:obligations).find { |row| row[:category] == "guam_income_tax_withheld" }
    expect(obligation[:due_date]).to eq(Date.new(2026, 7, 31))
  end
end
