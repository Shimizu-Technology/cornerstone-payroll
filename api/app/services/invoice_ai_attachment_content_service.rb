# frozen_string_literal: true

require "base64"
require "tempfile"

class InvoiceAiAttachmentContentService
  IMAGE_CONTENT_TYPES = {
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp"
  }.freeze
  MAX_ATTACHMENT_BYTES = Integer(ENV.fetch("INVOICE_AI_ATTACHMENT_MAX_BYTES", (8 * 1024 * 1024).to_s))
  PDF_RENDER_LIMIT = Integer(ENV.fetch("INVOICE_AI_PDF_RENDER_LIMIT", "4"))

  def initialize(references:, storage: R2StorageService.new)
    @references = Array(references).compact_blank
    @storage = storage
  end

  def content_parts
    references.flat_map do |reference|
      pdf_reference?(reference) ? pdf_content_parts(reference) : image_content_part(reference)
    end.compact
  end

  private

  attr_reader :references, :storage

  def image_content_part(reference)
    content_type = image_content_type(reference)
    return nil unless content_type

    data = download_reference(reference)
    return nil if data.blank?

    {
      type: "image_url",
      image_url: {
        url: "data:#{content_type};base64,#{Base64.strict_encode64(data)}"
      }
    }
  rescue R2StorageService::DownloadError => e
    Rails.logger.warn("Invoice AI attachment download failed: #{e.class}: #{e.message}")
    nil
  end

  def pdf_content_parts(reference)
    data = download_reference(reference)
    return [] if data.blank?

    rendered_images = []
    with_temp_pdf(data) do |pdf|
      rendered_images = TimecardOcr::CardSegmentationService.segment(pdf.path)
      rendered_images.first(PDF_RENDER_LIMIT).map { |image| image_file_part(image) }
    ensure
      rendered_images.each do |image|
        image&.close
        image&.unlink
      end
    end
  rescue R2StorageService::DownloadError => e
    Rails.logger.warn("Invoice AI PDF attachment download failed: #{e.class}: #{e.message}")
    []
  rescue StandardError => e
    Rails.logger.warn("Invoice AI PDF attachment render failed: #{e.class}: #{e.message}")
    []
  end

  def download_reference(reference)
    storage.download_with_limit(reference, max_bytes: MAX_ATTACHMENT_BYTES)
  end

  def with_temp_pdf(data)
    Tempfile.create([ "invoice-ai-attachment", ".pdf" ]) do |pdf|
      pdf.binmode
      pdf.write(data)
      pdf.flush
      yield pdf
    end
  end

  def image_file_part(file)
    file.rewind if file.respond_to?(:rewind)
    {
      type: "image_url",
      image_url: {
        url: "data:image/jpeg;base64,#{Base64.strict_encode64(file.read)}"
      }
    }
  ensure
    file.rewind if file.respond_to?(:rewind)
  end

  def pdf_reference?(reference)
    File.extname(reference.to_s).casecmp(".pdf").zero?
  end

  def image_content_type(reference)
    IMAGE_CONTENT_TYPES[File.extname(reference.to_s).downcase]
  end
end
