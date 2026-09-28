# frozen_string_literal: true

require "digest"
require "marcel"

class ExpenseArtifactStorageService
  MAX_FILE_SIZE = 15.megabytes
  CONTENT_TYPES = %w[application/pdf image/jpeg image/png image/webp].freeze

  def initialize(storage: R2StorageService.new)
    @storage = storage
  end

  def upload!(expense:, actor:, file:)
    raise ArgumentError, "Expense receipt is required" unless file
    raise ArgumentError, "Expense receipt exceeds the 15 MB limit" if file.size.to_i > MAX_FILE_SIZE

    file.tempfile.rewind
    content_type = Marcel::MimeType.for(file.tempfile, name: file.original_filename)
    raise ArgumentError, "Expense receipt must be a PDF, JPEG, PNG, or WebP" unless CONTENT_TYPES.include?(content_type)

    file.tempfile.rewind
    bytes = file.tempfile.read
    raise ArgumentError, "Expense receipt is empty" if bytes.blank?

    extension = { "application/pdf" => ".pdf", "image/jpeg" => ".jpg", "image/png" => ".png",
                  "image/webp" => ".webp" }.fetch(content_type)
    filename = File.basename(file.original_filename.to_s).gsub(/[^a-zA-Z0-9._-]/, "_").presence || "receipt#{extension}"
    key = "expense-ledger/organization-#{expense.organization_id}/expense-#{expense.id}/#{SecureRandom.uuid}#{extension}"
    @storage.upload(key, StringIO.new(bytes), content_type: content_type)

    expense.expense_artifacts.create!(
      organization: expense.organization,
      created_by: actor,
      storage_key: key,
      filename: filename,
      content_type: content_type,
      byte_size: bytes.bytesize,
      sha256: Digest::SHA256.hexdigest(bytes)
    )
  rescue StandardError
    if key.present?
      begin
        @storage.delete(key)
      rescue StandardError => cleanup_error
        Rails.logger.warn("Expense artifact cleanup failed: #{cleanup_error.class}: #{cleanup_error.message}")
      end
    end
    raise
  end

  def download(artifact)
    bytes = @storage.download(artifact.storage_key)
    raise R2StorageService::DownloadError, "Expense receipt is unavailable" if bytes.nil?
    raise R2StorageService::DownloadError, "Expense receipt failed integrity verification" unless Digest::SHA256.hexdigest(bytes) == artifact.sha256

    bytes
  end
end
