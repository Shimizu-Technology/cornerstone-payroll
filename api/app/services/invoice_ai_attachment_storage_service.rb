# frozen_string_literal: true

class InvoiceAiAttachmentStorageService
  ALLOWED_CONTENT_TYPES = %w[image/jpeg image/png image/webp application/pdf].freeze

  def self.upload(file, company_id:, session_id:)
    new(file, company_id: company_id, session_id: session_id).upload
  end

  def initialize(file, company_id:, session_id:)
    @file = file
    @company_id = company_id
    @session_id = session_id
  end

  def upload
    raise ArgumentError, "Unsupported attachment type" unless ALLOWED_CONTENT_TYPES.include?(content_type)

    key = "invoice-assistant/company-#{@company_id}/session-#{@session_id}/#{SecureRandom.uuid}#{extension}"
    R2StorageService.new.upload(key, @file.tempfile, content_type: content_type)
    key
  end

  private

  def content_type
    @file.content_type.to_s
  end

  def extension
    File.extname(@file.original_filename.to_s).presence || extension_for_content_type
  end

  def extension_for_content_type
    {
      "image/jpeg" => ".jpg",
      "image/png" => ".png",
      "image/webp" => ".webp",
      "application/pdf" => ".pdf"
    }.fetch(content_type, "")
  end
end
