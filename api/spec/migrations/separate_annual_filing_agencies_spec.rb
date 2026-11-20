# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261120150000_separate_annual_filing_agencies")

RSpec.describe SeparateAnnualFilingAgencies do
  let(:migration) { described_class.new.tap { |m| m.verbose = false } }
  let(:company) { create(:company) }

  def filing(**extra)
    PayrollFilingRecord.create!(company: company, filing_type: "w2_gu_w3_ss", tax_year: 2024,
      status: "submitted", submitted_at: 2.years.ago, confirmation_number: "OLD", source_fingerprint: "a" * 64, **extra)
  end

  it "preserves prior-year W-2 history as unassigned across rollback and migration" do
    old = filing
    prior1099 = filing(filing_type: "form_1099_nec")
    actor = create(:user, company: company, organization: company.organization)
    document = create(:client_document, company: company, uploaded_by: actor, category: "filing_evidence", visible_to_client: false)
    event = PayrollFilingEvent.create!(payroll_filing_record: old, company: company, recorded_by: actor,
      evidence_document: document, event_type: "submitted", to_status: "submitted", occurred_at: 2.years.ago,
      reference_number: "OLD", preparer_name: actor.name, source_fingerprint: "a" * 64, idempotency_key: SecureRandom.uuid)
    migration.down
    migration.up
    PayrollFilingRecord.reset_column_information
    expect(old.reload).to have_attributes(agency: "legacy", confirmation_number: "OLD", tax_year: 2024)
    expect(prior1099.reload.agency).to eq("drt")
    expect(event.reload).to have_attributes(reference_number: "OLD", evidence_document_id: document.id, payroll_filing_record_id: old.id)
  end

  it "refuses rollback with a count instead of discarding agency records" do
    old = filing(agency: "drt")
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /1 agency filing record/)
    expect(old.reload.agency).to eq("drt")
  end
end
