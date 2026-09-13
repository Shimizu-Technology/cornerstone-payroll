# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollLiabilityCheckAllocationService do
  let(:company) { create(:company) }
  let(:department) { create(:department, company:) }
  let(:employee) { create(:employee, company:, department:) }
  let(:period) do
    create(:pay_period, :committed, company:, start_date: Date.new(2026, 8, 1),
      end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 20))
  end
  let!(:item) do
    create(:payroll_item, company:, employee:, pay_period: period,
      withholding_tax: 100, social_security_tax: 62, employer_social_security_tax: 62)
  end
  let!(:posting) { PayrollLiabilityPostingService.post!(pay_period: period) }

  def payment(amount:, payable_to: "United States Treasury")
    create(:non_employee_check, company:, amount:, payable_to:, check_type: "tax_deposit")
  end

  it "reserves several categories for one real recipient payment" do
    check = payment(amount: 124)
    entries = posting.entries.where(authority: PayrollLiabilityPostingService::US_TREASURY)

    described_class.allocate!(non_employee_check: check, entry_ids: entries.pluck(:id))

    expect(check.payroll_liability_check_allocations.sum(:amount)).to eq(124)
    expect(check.payroll_liability_check_allocations.count).to eq(2)
  end

  it "prevents two prepared payments from reserving the same balance" do
    entries = posting.entries.where(authority: PayrollLiabilityPostingService::GUAM_DRT)
    described_class.allocate!(non_employee_check: payment(amount: 100, payable_to: "Treasurer of Guam"), entry_ids: entries.pluck(:id))

    expect {
      described_class.allocate!(
        non_employee_check: payment(amount: 1, payable_to: "Treasurer of Guam"),
        entry_ids: entries.pluck(:id)
      )
    }.to raise_error(described_class::Error, /no unreserved balance/)
  end

  it "rejects tenant crossings and mixed recipients" do
    other_company = create(:company)
    other_check = create(:non_employee_check, company: other_company, amount: 100)
    expect {
      described_class.allocate!(non_employee_check: other_check, entry_ids: posting.entries.pluck(:id))
    }.to raise_error(described_class::Error, /unavailable/)

    mixed_check = payment(amount: 224)
    expect {
      described_class.allocate!(non_employee_check: mixed_check, entry_ids: posting.entries.pluck(:id))
    }.to raise_error(described_class::Error, /one recipient/)
  end

  it "ignores reversed journal postings" do
    ids = posting.entries.pluck(:id)
    PayrollLiabilityPostingService.reverse!(pay_period: period, reason: "Voided payroll")

    expect {
      described_class.allocate!(non_employee_check: payment(amount: 100), entry_ids: ids)
    }.to raise_error(described_class::Error, /unavailable/)
  end
end
