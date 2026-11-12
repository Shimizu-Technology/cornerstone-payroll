# frozen_string_literal: true

class GenerateClientDocumentPreviewJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound
  retry_on StandardError, wait: :polynomially_longer, attempts: 2

  def perform(document_id)
    document = ClientDocument.find(document_id)
    return unless document.preview_generation_required?
    return if document.preview_ready?

    document.ensure_usable_for!(:preview)
    document.update!(preview_status: "processing", preview_error: nil)
    started_processing = true
    ClientDocumentPreviewGenerator.new(document: document).generate!
  rescue ClientDocumentScanner::Blocked, ClientDocumentPreviewGenerator::GenerationUnavailable, ClientDocumentPreviewGenerator::GenerationFailed => e
    if started_processing
      ClientDocument.where(id: document_id, preview_status: "processing")
        .update_all(preview_status: "failed", preview_error: e.message, updated_at: Time.current)
    end
    Rails.logger.warn("Client document preview generation failed for #{document_id}: #{e.message}")
  end
end
