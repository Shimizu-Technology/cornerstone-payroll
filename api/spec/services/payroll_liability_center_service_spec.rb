# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollLiabilityCenterService do
  let(:company) { create(:company) }
  let(:department) { create(:department, company:) }
  let(:employee) { create(:employee, company:, department:) }
  let(:actor) { create(:user, company:, organization: company.organization) }
  let(:period) do
    create(:pay_period, :committed, company:, start_date: Date.new(2026, 8, 1),
      end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 20))
  end
  let!(:item) do
    create(:payroll_item, company:, employee:, pay_period: period,
      withholding_tax: 100, social_security_tax: 62, employer_social_security_tax: 62)
  end
  let!(:posting) { PayrollLiabilityPostingService.post!(pay_period: period, actor:) }

  it "separates calculated, prepared, and explicitly paid amounts" do
    check = create(:non_employee_check, company:, amount: 124, payable_to: "United States Treasury",
      check_type: "tax_deposit", payment_method: "eftps", payment_date: Date.new(2026, 8, 21))
    PayrollLiabilityCheckAllocationService.allocate!(
      non_employee_check: check,
      entry_ids: posting.entries.where(authority: PayrollLiabilityPostingService::US_TREASURY).pluck(:id)
    )

    prepared = described_class.new(company:).call
    federal = prepared[:obligations].find { |row| row[:authority] == PayrollLiabilityPostingService::US_TREASURY }
    expect(federal).to include(
      calculated_amount: 124.0,
      prepared_amount: 124.0,
      paid_amount: 0.0,
      outstanding_amount: 124.0,
      unreserved_amount: 0.0,
      status: "prepared"
    )

    check.mark_paid!(actor:, payment_date: "2026-08-21", confirmation_number: "EFTPS-123")
    paid = described_class.new(company:).call
    federal = paid[:obligations].find { |row| row[:authority] == PayrollLiabilityPostingService::US_TREASURY }
    expect(federal).to include(paid_amount: 124.0, outstanding_amount: 0.0, status: "paid")
    expect(paid[:payments].first).to include(status: "paid", paid_by_name: actor.name)
  end

  it "releases a voided payment without erasing its audit row" do
    check = create(:non_employee_check, company:, amount: 100, payable_to: "Treasurer of Guam",
      check_type: "tax_deposit", payment_method: "check", payment_date: period.pay_date)
    PayrollLiabilityCheckAllocationService.allocate!(
      non_employee_check: check,
      entry_ids: posting.entries.where(authority: PayrollLiabilityPostingService::GUAM_DRT).pluck(:id)
    )
    check.mark_printed!
    check.mark_paid!(actor:, payment_date: period.pay_date.to_s)
    check.void!(reason: "Check rejected")

    result = described_class.new(company:).call
    drt = result[:obligations].find { |row| row[:authority] == PayrollLiabilityPostingService::GUAM_DRT }
    expect(drt).to include(paid_amount: 0.0, unreserved_amount: 100.0, status: "unpaid")
    expect(result[:payments].first).to include(status: "voided", void_reason: "Check rejected")
  end

  it "shows overdue obligations from an operator-reviewed due date" do
    PayrollLiabilityObligationDueDate.create!(company:, pay_period: period,
      authority: PayrollLiabilityPostingService::GUAM_DRT, due_date: Date.current - 1, updated_by: actor)

    result = described_class.new(company:).call
    drt = result[:obligations].find { |row| row[:authority] == PayrollLiabilityPostingService::GUAM_DRT }
    expect(drt[:status]).to eq("overdue")
    expect(result.dig(:totals, :overdue_count)).to eq(1)
  end

  it "can return one pay period without loading company-wide payment history" do
    other_period = create(:pay_period, :committed, company:, start_date: Date.new(2026, 8, 16),
      end_date: Date.new(2026, 8, 31), pay_date: Date.new(2026, 9, 5))
    create(:payroll_item, company:, employee:, pay_period: other_period,
      withholding_tax: 50, social_security_tax: 31, employer_social_security_tax: 31)
    PayrollLiabilityPostingService.post!(pay_period: other_period, actor:)

    result = described_class.new(company:, pay_period_id: period.id, include_payments: false).call

    expect(result[:obligations]).not_to be_empty
    expect(result[:obligations].pluck(:pay_period_id).uniq).to eq([ period.id ])
    expect(result[:payments]).to eq([])
  end
end
