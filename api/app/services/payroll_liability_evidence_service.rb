# frozen_string_literal: true

require "digest"
require "marcel"

class PayrollLiabilityEvidenceService
  MAX_FILE_SIZE = 15.megabytes
  CONTENT_TYPES = %w[application/pdf image/jpeg image/png image/webp].freeze

  def initialize(payment:, actor:, storage: R2StorageService.new)
    @payment = payment
    @actor = actor
    @storage = storage
  end

  def attach!(file:)
    bytes, content_type, filename = validate_file!(file)
    key = "payroll-liability-evidence/company-#{payment.company_id}/payment-#{payment.id}/#{SecureRandom.uuid}#{File.extname(filename)}"
    storage.upload(key, StringIO.new(bytes), content_type:)

    PayrollLiabilityEvidence.create!(
      company: payment.company,
      payroll_liability_payment: payment,
      created_by: actor,
      storage_key: key,
      filename:,
      content_type:,
      byte_size: bytes.bytesize,
      sha256: Digest::SHA256.hexdigest(bytes)
    )
  rescue StandardError
    cleanup(key)
    raise
  end

  def download!(evidence)
    raise ActiveRecord::RecordNotFound unless evidence.payroll_liability_payment_id == payment.id

    bytes = storage.download_with_limit(evidence.storage_key, max_bytes: MAX_FILE_SIZE)
    raise R2StorageService::DownloadError, "Payment evidence is unavailable" if bytes.nil?
    unless bytes.bytesize == evidence.byte_size && Digest::SHA256.hexdigest(bytes) == evidence.sha256
      raise R2StorageService::DownloadError, "Payment evidence failed integrity verification"
    end

    bytes
  end

  private

  attr_reader :payment, :actor, :storage

  def validate_file!(file)
    raise ArgumentError, "Evidence file is required" unless file
    raise ArgumentError, "Evidence file exceeds the 15 MB limit" if file.size.to_i > MAX_FILE_SIZE

    file.tempfile.rewind
    content_type = Marcel::MimeType.for(file.tempfile, name: file.original_filename)
    file.tempfile.rewind
    raise ArgumentError, "Evidence must be a PDF, JPEG, PNG, or WebP" unless content_type.in?(CONTENT_TYPES)

    bytes = file.tempfile.read
    file.tempfile.rewind
    raise ArgumentError, "Evidence file is empty" if bytes.blank?

    filename = File.basename(file.original_filename.to_s).gsub(/[^a-zA-Z0-9._-]/, "_").presence || "payment-evidence"
    [ bytes, content_type, filename ]
  end

  def cleanup(key)
    storage.delete(key) if key.present?
  rescue StandardError => error
    Rails.logger.warn("Payment evidence cleanup failed: #{error.class}: #{error.message}")
  end
end
