# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayPeriodPayDateCorrectionService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization) }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department) }
  let(:pay_period) do
    create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 6, 1),
      end_date: Date.new(2026, 6, 14),
      pay_date: Date.new(2026, 6, 19))
  end
  let!(:payroll_item) do
    create(:payroll_item,
      pay_period: pay_period,
      employee: employee,
      company: company,
      withholding_tax: 100,
      social_security_tax: 50,
      employer_social_security_tax: 50)
  end

  it "moves the active liability to the corrected pay date without changing payroll dollars" do
    original = PayrollLiabilityPostingService.post!(pay_period: pay_period, actor: actor)
    before_values = payroll_item.attributes.slice(
      "gross_pay", "net_pay", "withholding_tax", "social_security_tax", "employer_social_security_tax"
    )

    result = described_class.call(
      pay_period: pay_period,
      new_pay_date: Date.new(2026, 7, 3),
      reason: "Correct quarter-ending pay date",
      actor: actor
    )

    expect(result.noop).to be(false)
    expect(original.reload.reversal_posting).to be_present
    replacement = pay_period.payroll_liability_postings.find_by!(posting_type: "replacement")
    expect(replacement.liability_date).to eq(Date.new(2026, 7, 3))
    expect(replacement.entries.sum(:amount)).to eq(original.entries.sum(:amount))
    expect(payroll_item.reload.attributes.slice(*before_values.keys)).to eq(before_values)
  end

  it "does not touch liability history for a no-op correction" do
    PayrollLiabilityPostingService.post!(pay_period: pay_period, actor: actor)

    expect {
      described_class.call(
        pay_period: pay_period,
        new_pay_date: pay_period.pay_date,
        reason: "Confirm date",
        actor: actor
      )
    }.not_to change(PayrollLiabilityPosting, :count)
  end
end
