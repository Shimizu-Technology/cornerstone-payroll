# frozen_string_literal: true

require "digest"

class GeneralTransmittalArtifactService
  MAX_DOWNLOAD_BYTES = 20.megabytes
  Result = Data.define(:artifact, :pdf_bytes)

  def initialize(transmittal:, actor:, storage: R2StorageService.new)
    @transmittal = transmittal
    @actor = actor
    @storage = storage
  end

  def generate!
    storage_key = nil
    result = nil

    GeneralTransmittal.transaction do
      locked = GeneralTransmittal.lock.includes(:company, :pay_period, :items, :artifacts).find(transmittal.id)
      raise ArgumentError, "Include at least one item before generating" if locked.included_items.empty?

      generator = GeneralTransmittalPdfGenerator.new(locked)
      pdf_bytes = generator.generate
      version = locked.artifacts.maximum(:version_number).to_i + 1
      token = SecureRandom.uuid
      storage_key = "general-transmittals/company-#{locked.company_id}/transmittal-#{locked.id}/#{token}.pdf"
      filename = versioned_filename(generator.filename, version)
      storage.upload(storage_key, StringIO.new(pdf_bytes), content_type: "application/pdf")

      artifact = locked.artifacts.create!(
        company: locked.company,
        created_by: actor,
        version_number: version,
        storage_key: storage_key,
        filename: filename,
        content_type: "application/pdf",
        byte_size: pdf_bytes.bytesize,
        sha256: Digest::SHA256.hexdigest(pdf_bytes),
        template_version: GeneralTransmittalPdfGenerator::TEMPLATE_VERSION,
        snapshot: snapshot_for(locked)
      )
      locked.mark_generated!(actor: actor)
      result = Result.new(artifact:, pdf_bytes:)
    end

    result
  rescue StandardError
    cleanup_storage(storage_key)
    raise
  end

  def download!(artifact)
    raise ActiveRecord::RecordNotFound unless artifact.general_transmittal_id == transmittal.id

    bytes = storage.download_with_limit(artifact.storage_key, max_bytes: MAX_DOWNLOAD_BYTES)
    raise R2StorageService::DownloadError, "Generated transmittal version is unavailable" if bytes.nil?
    unless bytes.bytesize == artifact.byte_size && Digest::SHA256.hexdigest(bytes) == artifact.sha256
      raise R2StorageService::DownloadError, "Generated transmittal version failed integrity verification"
    end

    bytes
  end

  private

  attr_reader :transmittal, :actor, :storage

  def versioned_filename(filename, version)
    extension = File.extname(filename)
    base = File.basename(filename, extension)
    "#{base}_v#{version}#{extension}"
  end

  def snapshot_for(record)
    {
      id: record.id,
      company_id: record.company_id,
      pay_period_id: record.pay_period_id,
      source_kind: record.source_kind,
      title: record.title,
      transmittal_date: record.transmittal_date,
      preparer_name: record.preparer_name,
      recipient_name: record.recipient_name,
      notes: record.notes,
      items: record.included_items.map do |item|
        item.attributes.slice("id", "source_key", "item_type", "title", "payable_to", "check_number", "amount", "details", "position", "metadata")
      end
    }
  end

  def cleanup_storage(key)
    storage.delete(key) if key.present?
  rescue StandardError => error
    Rails.logger.warn("Transmittal artifact cleanup failed: #{error.class}: #{error.message}")
  end
end
