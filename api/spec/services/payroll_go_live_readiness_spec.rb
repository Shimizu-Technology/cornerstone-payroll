# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollGoLiveReadiness do
  let(:company) { create(:company) }
  let(:source_company) { create(:company, organization: company.organization) }
  let(:batch) { create(:historical_import_batch, company: company, status: "locked") }
  let(:review) do
    PayrollGoLiveReview.create!(
      company: company,
      source_company: source_company,
      historical_import_batch: batch,
      effective_on: Date.new(2026, 10, 1),
      plan_digest: "c" * 64,
      status: "setup_applied",
      setup_applied_at: Time.current,
      attestations: {},
      validation_errors: []
    )
  end

  it "blocks cutover while an active employee still has free-text recurring payroll behavior" do
    create(
      :employee,
      company: company,
      default_payroll_adjustments: [
        { "label" => "Legacy reimbursement", "amount" => 25, "treatment" => "non_taxable_addition", "active" => true }
      ]
    )

    readiness = described_class.new(review)

    expect(readiness.blockers).to include("Move every legacy recurring earning and adjustment to typed payroll fields")
    expect(readiness.facts.fetch("legacy_recurring_components")).to eq(1)
  end
end
