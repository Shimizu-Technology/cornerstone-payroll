# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollCompanySetupReview do
  let(:organization) { create(:organization) }
  let(:company) do
    create(
      :company,
      organization:,
      name: "MoSa's successor",
      ein: "66-1234567",
      address_line1: "123 Marine Corps Drive",
      city: "Tamuning",
      state: "GU",
      zip: "96913"
    )
  end
  let(:source_company) { create(:company, organization:) }
  let(:batch) { create(:historical_import_batch, company:, status: "locked") }
  let(:actor) { create(:user, company:, organization:, role: "accountant") }
  let(:review) do
    PayrollGoLiveReview.create!(
      company:,
      source_company:,
      historical_import_batch: batch,
      created_by: actor,
      effective_on: Date.new(2026, 9, 21),
      plan_digest: "c" * 64,
      status: "setup_applied",
      setup_applied_at: Time.current,
      setup_applied_by: actor
    )
  end

  before { create(:company_assignment, company:, user: actor) }

  it "records an attributed review and detects later company changes" do
    service = described_class.new(review)

    expect do
      service.confirm!(
        actor:,
        acknowledgement: described_class::ACKNOWLEDGEMENT,
        notes: "Matched EIN and filing address to the employer records."
      )
    end.to change(AuditLog.where(action: "payroll_go_live#review_company_setup"), :count).by(1)

    expect(service.state).to include(status: "current", current: true, reviewed_by_name: actor.name)
    company.update!(address_line1: "456 Marine Corps Drive")
    expect(service.state).to include(status: "stale", current: false)
    expect(PayrollGoLiveReadiness.new(review).blockers).to include(/Re-review company setup/)
  end

  it "does not allow required legal-employer fields to be waved through" do
    company.update_column(:ein, nil)

    expect do
      described_class.new(review).confirm!(
        actor:,
        acknowledgement: described_class::ACKNOWLEDGEMENT,
        notes: "Reviewed available fields."
      )
    end.to raise_error(ArgumentError, /EIN/)

    expect(described_class.new(review).state).to include(
      status: "missing_required",
      missing_required_fields: include("ein")
    )
  end
end
