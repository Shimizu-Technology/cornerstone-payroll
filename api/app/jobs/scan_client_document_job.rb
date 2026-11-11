# frozen_string_literal: true

class ScanClientDocumentJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(document_id)
    document = ClientDocument.find(document_id)
    return unless document.scan_status == "pending"

    recorded = ClientDocumentScanner.scan!(document)
    if recorded && document.scan_status == "clean" && document.preview_generation_required? && !document.archived?
      GenerateClientDocumentPreviewJob.perform_later(document.id)
    end
  end
end
