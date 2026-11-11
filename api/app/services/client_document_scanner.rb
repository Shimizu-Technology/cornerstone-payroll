# frozen_string_literal: true

# PR 1b supplies an adapter with initial_status, scan(document:, storage:), and
# allowed?(document:, purpose:). Until then, no malware clearance is asserted.
class ClientDocumentScanner
  class Blocked < StandardError; end
  class Noop
    def initial_status = "not_scanned"
    def scan(document:, storage:) = "not_scanned"
    def allowed?(document:, purpose:) = true
  end

  class_attribute :adapter, default: Noop.new
  PURPOSES = %i[download preview message_attachment intake].freeze

  def self.ensure_allowed!(document, purpose:)
    raise ArgumentError, "Unknown document use" unless PURPOSES.include?(purpose)
    return if !%w[infected error pending].include?(document.scan_status) && adapter.allowed?(document: document, purpose: purpose)

    raise Blocked, "This file is not available yet. Its safety check must finish before it can be used. Please try again later or contact Cornerstone."
  end

  # Returns true only when this scan recorded the result. Recovery can start a
  # second scan of the same file, so a result is kept only if no other scan
  # changed the status after this one started.
  def self.scan!(document, storage: R2StorageService.new)
    started_from = document.scan_status
    begin
      status = adapter.scan(document: document, storage: storage).to_s
      raise ArgumentError, "Invalid scanner result" unless ClientDocument::SCAN_STATUSES.include?(status)

      settle!(document, from: started_from, to: status)
    rescue StandardError
      settle!(document, from: started_from, to: "error")
      raise
    end
  end

  def self.settle!(document, from:, to:)
    recorded = ClientDocument.where(id: document.id, scan_status: from)
      .update_all(scan_status: to, updated_at: Time.current) == 1
    document.reload
    recorded
  end
  private_class_method :settle!
end
