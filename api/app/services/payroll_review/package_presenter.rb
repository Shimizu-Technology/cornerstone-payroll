# frozen_string_literal: true

module PayrollReview
  class PackagePresenter
    def self.call(review_package)
      return nil unless review_package

      {
        id: review_package.id,
        revision: review_package.revision,
        schema_version: review_package.schema_version,
        calculation_checksum: review_package.calculation_checksum,
        checksum_short: review_package.calculation_checksum.first(12),
        status: review_package.status,
        source_manifest: review_package.source_manifest,
        generated_at: review_package.generated_at,
        generated_by_name: review_package.generated_by&.name,
        approved_at: review_package.approved_at,
        approved_by_id: review_package.approved_by_id,
        approved_by_name: review_package.approved_by&.name,
        approval_recorded_by_name: review_package.approval_recorded_by&.name,
        approval_method: review_package.approval_method,
        approval_notes: review_package.approval_notes,
        approval_evidence_reference: review_package.approval_evidence_reference,
        acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
      }
    end
  end
end
