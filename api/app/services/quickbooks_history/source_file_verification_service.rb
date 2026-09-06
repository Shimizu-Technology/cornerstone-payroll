# frozen_string_literal: true

require "digest"

module QuickbooksHistory
  class SourceFileVerificationService
    Result = Struct.new(:all_verified, :files, keyword_init: true)

    def initialize(batch:, actor:, storage: R2StorageService.new, audit: true)
      @batch = batch
      @actor = actor
      @storage = storage
      @audit = audit
    end

    def call
      files = batch.historical_import_source_files.in_manifest_order.to_a
      files.each { |source_file| verify(source_file) }
      all_verified = batch.reload.source_files_complete_and_verified?
      record_audit!(files, all_verified) if audit
      Result.new(all_verified: all_verified, files: files)
    end

    def verified_bytes!(source_file)
      bytes = storage.download_with_limit(source_file.storage_key, max_bytes: BundleParser::MAX_FILE_BYTES)
      unless valid_bytes?(source_file, bytes)
        record_result(source_file, status: "failed", error: "Stored file does not match its source fingerprint")
        raise R2StorageService::DownloadError, "Historical source file failed integrity verification"
      end

      record_result(source_file, status: "verified", error: nil)
      bytes
    rescue R2StorageService::DownloadError => e
      raise if source_file.verification_error == "Stored file does not match its source fingerprint"

      record_result(source_file, status: "failed", error: "Stored file is unavailable or could not be verified")
      raise e
    end

    private

    attr_reader :batch, :actor, :storage, :audit

    def verify(source_file)
      verified_bytes!(source_file)
    rescue R2StorageService::DownloadError, R2StorageService::ConfigurationError
      nil
    end

    def valid_bytes?(source_file, bytes)
      bytes.present? && bytes.bytesize == source_file.byte_size &&
        ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(bytes), source_file.sha256)
    end

    def record_result(source_file, status:, error:)
      source_file.update_columns(
        verification_status: status,
        verified_at: Time.current,
        verification_error: error,
        updated_at: Time.current
      )
    end

    def record_audit!(files, all_verified)
      AuditLog.record!(
        user: actor,
        organization_id: batch.company.organization_id,
        company_id: batch.company_id,
        action: "historical_imports#verify_source_files",
        record_type: "historical_import_batches",
        record_id: batch.id,
        subject_name: batch.source_label,
        metadata: {
          source_file_count: files.size,
          verified_file_count: files.count(&:verified?),
          all_verified: all_verified
        }
      )
    end
  end
end
