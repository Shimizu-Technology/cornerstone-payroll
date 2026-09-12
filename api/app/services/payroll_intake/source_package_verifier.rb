# frozen_string_literal: true

require "digest"

module PayrollIntake
  class SourcePackageVerifier
    class VerificationError < StandardError; end

    def initialize(session:, storage: R2StorageService.new)
      @session = session
      @storage = storage
    end

    def verify!
      session.documents.in_package_order.each { |document| verified_bytes!(document) }
      true
    end

    def verified_bytes!(document)
      return nil if document.verification_status == "legacy_unverified"

      bytes = source_bytes(document)
      unless valid_bytes?(document, bytes)
        record_failure!(document)
        raise VerificationError, "A retained payroll source no longer matches its original fingerprint. Preview the source package again."
      end

      document.update_columns(
        verification_status: "verified",
        verified_at: Time.current,
        verification_error: nil,
        updated_at: Time.current
      )
      bytes
    rescue R2StorageService::DownloadError, R2StorageService::ConfigurationError
      record_failure!(document)
      raise VerificationError, "A retained payroll source is unavailable. Restore it or preview the source package again."
    end

    private

    attr_reader :session, :storage

    def source_bytes(document)
      if document.storage_reference.present?
        storage.download_with_limit(document.storage_reference, max_bytes: PayrollIntake::PreviewService::MAX_FILE_BYTES)
      else
        document.text_content.to_s.b
      end
    end

    def valid_bytes?(document, bytes)
      bytes.present? &&
        bytes.bytesize == document.byte_size.to_i &&
        ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(bytes), document.sha256.to_s)
    end

    def record_failure!(document)
      document.update_columns(
        verification_status: "failed",
        verified_at: Time.current,
        verification_error: "Stored source failed integrity verification",
        updated_at: Time.current
      )
    end
  end
end
