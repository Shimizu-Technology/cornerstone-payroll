# frozen_string_literal: true

require "marcel"

class InvoiceAiAttachmentStorageService
  ALLOWED_CONTENT_TYPES = %w[image/jpeg image/png image/webp application/pdf].freeze

  def self.upload(file, organization_id:, session_id:)
    new(file, organization_id: organization_id, session_id: session_id).upload
  end

  def initialize(file, organization_id:, session_id:)
    @file = file
    @organization_id = organization_id
    @session_id = session_id
  end

  def upload
    raise ArgumentError, "Unsupported attachment type" unless ALLOWED_CONTENT_TYPES.include?(detected_content_type)

    key = "invoice-assistant/organization-#{@organization_id}/session-#{@session_id}/#{SecureRandom.uuid}#{extension}"
    R2StorageService.new.upload(key, @file.tempfile, content_type: detected_content_type)
    key
  end

  private

  def detected_content_type
    @detected_content_type ||= begin
      @file.tempfile.rewind if @file.tempfile.respond_to?(:rewind)
      Marcel::MimeType.for(@file.tempfile, name: @file.original_filename)
    ensure
      @file.tempfile.rewind if @file.tempfile.respond_to?(:rewind)
    end
  end

  def extension
    extension_for_content_type
  end

  def extension_for_content_type
    {
      "image/jpeg" => ".jpg",
      "image/png" => ".png",
      "image/webp" => ".webp",
      "application/pdf" => ".pdf"
    }.fetch(detected_content_type, "")
  end
end
