# frozen_string_literal: true

class GenerateClientDocumentPreviewJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound
  retry_on StandardError, wait: :polynomially_longer, attempts: 2

  def perform(document_id)
    document = ClientDocument.find(document_id)
    return unless document.preview_generation_required?
    return if document.preview_ready?

    document.update!(preview_status: "processing", preview_error: nil)
    ClientDocumentPreviewGenerator.new(document: document).generate!
  rescue ClientDocumentPreviewGenerator::GenerationUnavailable, ClientDocumentPreviewGenerator::GenerationFailed => e
    Rails.logger.warn("Client document preview generation failed for #{document_id}: #{e.message}")
  end
end
