# frozen_string_literal: true

require "digest"
require "securerandom"

module QuickbooksHistory
  class SourceFileStorageService
    class StorageError < StandardError; end

    CONTENT_TYPES = {
      ".xls" => "application/vnd.ms-excel",
      ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      ".pdf" => "application/pdf",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".png" => "image/png"
    }.freeze

    def initialize(company:, actor:, storage: R2StorageService.new)
      @company = company
      @actor = actor
      @storage = storage
    end

    def store!(parsed:)
      manifest = Array(parsed.manifest)
      source_files = Array(parsed.source_files)
      raise StorageError, "QuickBooks source-file inventory is incomplete" unless manifest.size == source_files.size

      stored_keys = []
      bundle_key = SecureRandom.uuid
      records = source_files.each_with_index.map do |source, position|
        entry = manifest.fetch(position).with_indifferent_access
        validate_source!(source, entry, position)
        key = storage_key(bundle_key, position, source.original_filename)
        stored_keys << key

        File.open(source.path, "rb") do |io|
          storage.upload(key, io, content_type: content_type_for(source.original_filename))
        end
        verify_download!(key, entry.fetch(:byte_size).to_i, entry.fetch(:sha256).to_s)

        {
          company: company,
          uploaded_by: actor,
          original_filename: entry.fetch(:filename),
          content_type: content_type_for(source.original_filename),
          byte_size: entry.fetch(:byte_size).to_i,
          sha256: entry.fetch(:sha256).to_s,
          storage_key: key,
          report_type: entry.fetch(:report_type),
          position: position,
          verification_status: "verified",
          verified_at: Time.current
        }
      end
      records
    rescue StorageError
      cleanup(stored_keys)
      raise
    rescue StandardError => e
      cleanup(stored_keys)
      Rails.logger.error("QuickBooks source retention failed: #{e.class}: #{e.message}")
      raise StorageError, "QuickBooks source files could not be retained and verified. No preview was created."
    end

    def cleanup(records_or_keys)
      Array(records_or_keys).each do |record_or_key|
        key = if record_or_key.respond_to?(:storage_key)
          record_or_key.storage_key
        elsif record_or_key.respond_to?(:fetch)
          record_or_key.fetch(:storage_key)
        else
          record_or_key.to_s
        end
        storage.delete(key)
      rescue StandardError => e
        Rails.logger.error("QuickBooks source retention cleanup failed for #{key}: #{e.class}: #{e.message}")
      end
    end

    private

    attr_reader :company, :actor, :storage

    def validate_source!(source, entry, position)
      actual_size = File.size(source.path)
      actual_sha256 = Digest::SHA256.file(source.path).hexdigest
      valid = entry.fetch(:position, position).to_i == position &&
        entry.fetch(:filename) == File.basename(source.original_filename.to_s).gsub(/[\u0000-\u001f]/, "").truncate(240) &&
        entry.fetch(:byte_size).to_i == actual_size &&
        ActiveSupport::SecurityUtils.secure_compare(entry.fetch(:sha256).to_s, actual_sha256)
      return if valid

      raise StorageError, "QuickBooks source file changed while the bundle was being staged"
    end

    def verify_download!(key, expected_size, expected_sha256)
      bytes = storage.download_with_limit(key, max_bytes: BundleParser::MAX_FILE_BYTES)
      valid = bytes.present? && bytes.bytesize == expected_size &&
        ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(bytes), expected_sha256)
      return if valid

      raise StorageError, "QuickBooks source file could not be verified after upload"
    end

    def storage_key(bundle_key, position, filename)
      extension = File.extname(filename.to_s).downcase
      "historical-payroll/company-#{company.id}/#{bundle_key}/source-#{position.to_s.rjust(2, '0')}#{extension}"
    end

    def content_type_for(filename)
      CONTENT_TYPES.fetch(File.extname(filename.to_s).downcase, "application/octet-stream")
    end
  end
end
