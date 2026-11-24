# frozen_string_literal: true

module EmployeeDocuments
  class FreezePdf
    # The caller owns the source lock and transaction.
    def self.call(bytes:, source:, posted_at:, revision:, predecessor: nil, payment_line: nil)
      source_name = source.model_name.singular
      digest = Digest::SHA256.hexdigest(bytes)
      path = "employee_documents/company_#{source.company_id}/#{source_name}_#{source.id}/#{revision}-#{digest}.pdf"
      key = StagingStoragePolicy.new_key(path)
      document = EmployeeDocument.create!(
        source_name => source, company_id: source.company_id, revision: revision,
        storage_key: key, sha256: digest, posted_at: posted_at,
        payment_line: payment_line, corrected: predecessor.present?, replaces_document: predecessor
      )
      R2StorageService.new.upload(key, bytes, content_type: "application/pdf")
      document
    end
  end
end
