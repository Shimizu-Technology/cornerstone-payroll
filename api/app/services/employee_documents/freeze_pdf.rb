# frozen_string_literal: true

module EmployeeDocuments
  class FreezePdf
    # The caller owns the source lock and transaction. A W-2GU copy's source
    # is the employee, with its tax_year (M4-5).
    def self.call(bytes:, source:, posted_at:, revision:, predecessor: nil, payment_line: nil, payroll_facts: nil, tax_year: nil)
      source_name = source.model_name.singular
      digest = Digest::SHA256.hexdigest(bytes)
      key = storage_key(source: source, revision: revision, digest: digest, tax_year: tax_year)
      if block_given?
        key = key.sub(/\.pdf\z/, "-#{SecureRandom.uuid}.pdf")
        yield key
      end
      document = EmployeeDocument.create!(
        source_name => source, company_id: source.company_id, revision: revision, tax_year: tax_year,
        storage_key: key, sha256: digest, posted_at: posted_at,
        **(payroll_facts || {}), payment_line: payment_line, corrected: predecessor.present?, replaces_document: predecessor
      )
      R2StorageService.new.upload(key, bytes, content_type: "application/pdf")
      document
    end

    # An upload made before the caller takes its locks (W-2GU copies, M4-5),
    # so no lock is held while storage is slow. record_staged! then writes
    # the row; a staged file whose row never commits is the caller's to
    # remove (remove_uncommitted_object).
    Staged = Struct.new(:key, :sha256, keyword_init: true)

    def self.stage(bytes:, source:, revision:, tax_year: nil)
      digest = Digest::SHA256.hexdigest(bytes)
      key = storage_key(source: source, revision: revision, digest: digest, tax_year: tax_year)
        .sub(/\.pdf\z/, "-#{SecureRandom.uuid}.pdf")
      R2StorageService.new.upload(key, bytes, content_type: "application/pdf")
      Staged.new(key: key, sha256: digest)
    end

    def self.record_staged!(staged, source:, posted_at:, revision:, payroll_facts: nil, tax_year: nil)
      EmployeeDocument.create!(
        source.model_name.singular => source, company_id: source.company_id, revision: revision, tax_year: tax_year,
        storage_key: staged.key, sha256: staged.sha256, posted_at: posted_at, **(payroll_facts || {})
      )
    end

    def self.storage_key(source:, revision:, digest:, tax_year: nil)
      folder = "#{source.model_name.singular}_#{source.id}#{"/w2gu_#{tax_year}" if tax_year}"
      StagingStoragePolicy.new_key("employee_documents/company_#{source.company_id}/#{folder}/#{revision}-#{digest}.pdf")
    end

    def self.remove_uncommitted_object(key)
      R2StorageService.new.delete(key)
    rescue StandardError => error
      Rails.logger.error("Employee document rollback cleanup failed (#{error.class})")
      Rails.error.report(error, handled: true)
    end
  end
end
