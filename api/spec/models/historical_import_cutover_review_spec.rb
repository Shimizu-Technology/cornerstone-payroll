# frozen_string_literal: true

require "rails_helper"

RSpec.describe HistoricalImportCutoverReview do
  it "enforces the batch and review company match in the database" do
    batch_company = create(:company)
    other_company = create(:company, organization: batch_company.organization)
    batch = HistoricalImportBatch.create!(
      company: batch_company,
      source_label: "Tenant constraint rehearsal",
      bundle_digest: SecureRandom.hex(32),
      importer_version: QuickbooksHistory::BundleParser::IMPORTER_VERSION,
      status: "applied"
    )

    expect do
      described_class.insert_all!([ {
        company_id: other_company.id,
        historical_import_batch_id: batch.id,
        status: "pending",
        evidence: {},
        exception_dispositions: {},
        attestations: {},
        created_at: Time.current,
        updated_at: Time.current
      } ])
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
