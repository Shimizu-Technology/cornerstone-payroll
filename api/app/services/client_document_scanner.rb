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
    return if adapter.allowed?(document: document, purpose: purpose)

    raise Blocked, "This file is not available yet. Its safety check must finish before it can be used. Please try again later or contact Cornerstone."
  end

  def self.scan!(document, storage: R2StorageService.new)
    status = adapter.scan(document: document, storage: storage).to_s
    raise ArgumentError, "Invalid scanner result" unless ClientDocument::SCAN_STATUSES.include?(status)

    document.update!(scan_status: status)
  rescue StandardError
    document.update!(scan_status: "error")
    raise
  end
end
