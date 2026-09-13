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
        { "label" => "Legacy reimbursement", "amount" => BigDecimal("25.00"), "treatment" => "non_taxable_addition", "active" => true }
      ]
    )

    readiness = described_class.new(review)

    expect(readiness.blockers).to include("Move every legacy recurring earning and adjustment to typed payroll fields")
    expect(readiness.facts.fetch("legacy_recurring_components")).to eq(1)
  end

  it "blocks cutover while an active employee has unresolved required documents" do
    actor = create(:user, company: company)
    employee = create(:employee, company: company)
    EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: actor)
    verified = employee.employee_document_requirements.find_by!(requirement_type: "identity_and_work_authorization")
    document = create(:client_document, company: company, employee: employee, uploaded_by: actor)
    verified.update!(
      client_document: document,
      status: "verified",
      received_at: Time.current,
      reviewed_by: actor,
      reviewed_at: Time.current,
      review_note: "Verified against signed source"
    )

    readiness = described_class.new(review)

    expect(readiness.blockers).to include("Resolve every required employee document checklist")
    expect(readiness.facts.fetch("employee_document_gaps")).to eq(1)
  end

  it "blocks cutover when an opted-in employee is missing checklist rows" do
    create(:employee, company: company, document_readiness_required: true)

    readiness = described_class.new(review)

    expect(readiness.blockers).to include("Resolve every required employee document checklist")
    expect(readiness.facts.fetch("employee_document_gaps")).to eq(2)
  end

  it "accepts a complete verified document checklist" do
    actor = create(:user, company: company)
    employee = create(:employee, company: company)
    EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: actor)
    employee.employee_document_requirements.each do |requirement|
      document = create(:client_document, company: company, employee: employee, uploaded_by: actor)
      requirement.update!(
        client_document: document,
        status: "verified",
        received_at: Time.current,
        reviewed_by: actor,
        reviewed_at: Time.current,
        review_note: "Verified against signed source"
      )
    end

    readiness = described_class.new(review)

    expect(readiness.facts.fetch("employee_document_gaps")).to eq(0)
    expect(readiness.blockers).not_to include("Resolve every required employee document checklist")
  end
end
