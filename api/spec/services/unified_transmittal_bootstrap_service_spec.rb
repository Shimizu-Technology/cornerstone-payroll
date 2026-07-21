# frozen_string_literal: true

require "rails_helper"

RSpec.describe UnifiedTransmittalBootstrapService do
  let(:company) { create(:company, name: "Mosa's Hotbox") }
  let(:actor) { create(:user, company: company, name: "Dafne") }
  let(:pay_period) do
    create(:pay_period, :calculated,
      company: company,
      start_date: Date.new(2026, 6, 14),
      end_date: Date.new(2026, 6, 27),
      pay_date: Date.new(2026, 7, 3))
  end
  let(:employee) { create(:employee, company: company, first_name: "Maria", last_name: "Santos") }

  before do
    create(:payroll_item, :with_check,
      pay_period: pay_period,
      employee: employee,
      withholding_tax: 42.00,
      additional_withholding: 8.00,
      social_security_tax: 74.40,
      employer_social_security_tax: 74.40,
      medicare_tax: 26.40,
      additional_medicare_tax: 9.00,
      employer_medicare_tax: 17.40)
    create(:non_employee_check, :with_check_number,
      company: company,
      pay_period: pay_period,
      payable_to: "Treasurer of Guam",
      amount: 50.00)
  end

  subject(:service) { described_class.new(pay_period: pay_period, actor: actor) }

  it "builds one editable packet from checks, reports, and calculated obligations" do
    transmittal = service.call

    expect(transmittal).to be_pay_period_source
    expect(transmittal.pay_period).to eq(pay_period)
    expect(transmittal.items.pluck(:source_key)).to include(
      a_string_starting_with("payroll_item:"),
      a_string_starting_with("non_employee_check:"),
      "report:payroll_register",
      "tax_obligation:income_tax"
    )

    income_tax = transmittal.items.find_by!(source_key: "tax_obligation:income_tax")
    expect(income_tax.amount).to eq(50.00)
    expect(income_tax.metadata).to include("calculated_only" => true)
    expect(income_tax.details.join(" ")).to include("Payment is not recorded")

    employee_medicare = transmittal.items.find_by!(source_key: "tax_obligation:employee_medicare")
    employer_medicare = transmittal.items.find_by!(source_key: "tax_obligation:employer_medicare")
    expect(employee_medicare.amount).to eq(26.40)
    expect(employer_medicare.amount).to eq(17.40)
  end

  it "is idempotent and preserves operator edits while appending new source rows" do
    first = service.call
    report = first.items.find_by!(source_key: "report:payroll_register")
    report.update!(title: "CEO payroll register", included: false)

    second = service.call

    expect(second.id).to eq(first.id)
    expect(second.items.where(source_key: "report:payroll_register").count).to eq(1)
    expect(second.items.find_by!(source_key: "report:payroll_register")).to have_attributes(
      title: "CEO payroll register",
      included: false
    )
  end

  it "adds evidence-backed settlement rows and refreshes proof and reversal state" do
    pay_period.update!(status: "committed", committed_at: Time.current, committed_by_id: actor.id)
    PayrollLiabilityPostingService.post!(pay_period:, actor:)
    payment = PayrollLiabilitySettlementService.record!(
      pay_period:,
      actor:,
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      category: "guam_income_tax_withheld",
      amount: 25,
      payment_date: "2026-07-20",
      payment_method: "ach",
      confirmation_number: "DRT-25"
    )

    transmittal = service.call
    item = transmittal.items.find_by!(source_key: "payroll_liability_payment:#{payment.id}")
    expect(item).to have_attributes(item_type: "payment", amount: 25.00, included: true)
    expect(item.details.join(" ")).to include("Evidence not attached")

    PayrollLiabilityEvidence.create!(
      company:,
      payroll_liability_payment: payment,
      created_by: actor,
      storage_key: "test/liability-receipt.pdf",
      filename: "liability-receipt.pdf",
      content_type: "application/pdf",
      byte_size: 12,
      sha256: "a" * 64
    )
    item.update!(included: false)

    refreshed = service.call.items.find_by!(source_key: item.source_key)
    expect(refreshed.included).to be(false)
    expect(refreshed.details.join(" ")).to include("Evidence: liability-receipt.pdf")

    PayrollLiabilitySettlementService.reverse!(
      pay_period:,
      actor:,
      source_payment: payment,
      reason: "Transfer rejected"
    )
    reversed = service.call.items.find_by!(source_key: item.source_key)
    expect(reversed.included).to be(false)
    expect(reversed.details.join(" ")).to include("Reversed", "Transfer rejected")
  end
end
