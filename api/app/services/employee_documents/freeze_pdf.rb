# frozen_string_literal: true

module EmployeeDocuments
  class FreezePdf
    # The caller owns the source lock and transaction.
    def self.call(bytes:, source:, posted_at:, revision:, predecessor: nil, payment_line: nil, payroll_facts: nil)
      source_name = source.model_name.singular
      digest = Digest::SHA256.hexdigest(bytes)
      path = "employee_documents/company_#{source.company_id}/#{source_name}_#{source.id}/#{revision}-#{digest}.pdf"
      key = StagingStoragePolicy.new_key(path)
      if block_given?
        key = key.sub(/\.pdf\z/, "-#{SecureRandom.uuid}.pdf")
        yield key
      end
      document = EmployeeDocument.create!(
        source_name => source, company_id: source.company_id, revision: revision,
        storage_key: key, sha256: digest, posted_at: posted_at,
        **(payroll_facts || {}), payment_line: payment_line, corrected: predecessor.present?, replaces_document: predecessor
      )
      R2StorageService.new.upload(key, bytes, content_type: "application/pdf")
      document
    end

    def self.remove_uncommitted_object(key)
      R2StorageService.new.delete(key)
    rescue StandardError => error
      Rails.logger.error("Employee document rollback cleanup failed (#{error.class})")
      Rails.error.report(error, handled: true)
    end
  end
end
