# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollParallelRunReviewService do
  let(:company) { create(:company) }
  let(:source_company) { create(:company, organization: company.organization) }
  let(:actor) { create(:user, company:, organization: company.organization, role: "accountant") }
  let(:batch) { create(:historical_import_batch, company:, status: "locked") }
  let(:review) do
    PayrollGoLiveReview.create!(
      company:, source_company:, historical_import_batch: batch, created_by: actor,
      effective_on: Date.new(2026, 9, 21), plan_digest: "a" * 64, status: "setup_applied",
      setup_applied_at: Time.current, setup_applied_by: actor
    )
  end
  let(:pay_period) { create(:pay_period, :approved, company:, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 14), pay_date: Date.new(2026, 9, 18)) }

  before do
    create(:company_assignment, user: actor, company:)
    employee = create(:employee, company:)
    create(:payroll_item, pay_period:, employee:, gross_pay: 1_000, net_pay: 750,
      withholding_tax: 100, social_security_tax: 62, medicare_tax: 14.50,
      total_deductions: 250)
  end

  it "snapshots separate tax and non-tax deduction totals and makes the run non-committable" do
    record = described_class.new(
      review:, pay_period:, actor:, notes: "Compared against final QuickBooks preview",
      source_totals: { employee_count: 1, gross_pay: 1_000, net_pay: 750, taxes: 176.50, deductions: 73.50 }
    ).call!

    expect(record).to be_pass
    expect(record.cornerstone_taxes).to eq(176.50.to_d)
    expect(record.cornerstone_deductions).to eq(73.50.to_d)
    expect(pay_period.reload).to be_parallel_run
    expect { pay_period.update!(parallel_run: false) }
      .to raise_error(ActiveRecord::RecordInvalid, /cannot be cleared/)
    pay_period.reload
    expect { pay_period.update!(status: "committed") }.to raise_error(ActiveRecord::RecordInvalid, /parallel comparison run/)
    pay_period.reload
    expect do
      PayPeriodLifecycleService.new(pay_period:, actor:).commit!
    end.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Parallel comparison payroll cannot be committed/)
  end

  it "counts saved Medicare once and classifies extra withholding as tax" do
    pay_period.payroll_items.first.update!(medicare_tax: 19, additional_medicare_tax: 4.50, additional_withholding: 25)
    record = described_class.new(
      review:, pay_period:, actor:, notes: "Compared tax components against source",
      source_totals: { employee_count: 1, gross_pay: 1_000, net_pay: 750, taxes: 206, deductions: 44 }
    ).call!

    expect(record).to be_pass
    expect(record.cornerstone_taxes).to eq(206.to_d)
    expect(record.cornerstone_deductions).to eq(44.to_d)
  end

  it "records a failure when the source does not reconcile" do
    record = described_class.new(
      review:, pay_period:, actor:, notes: "Employee count differs",
      source_totals: { employee_count: 2, gross_pay: 1_000, net_pay: 750, taxes: 176.50, deductions: 73.50 }
    ).call!

    expect(record).not_to be_pass
    expect(record.differences.fetch("employee_count")).to eq(-1)
  end

  it "rejects negative source aggregates" do
    expect do
      described_class.new(
        review:, pay_period:, actor:, notes: "Invalid source export",
        source_totals: { employee_count: 1, gross_pay: -1, net_pay: 750, taxes: 176.50, deductions: 73.50 }
      ).call!
    end.to raise_error(ArgumentError, /gross pay must be zero or greater/)
  end
end
