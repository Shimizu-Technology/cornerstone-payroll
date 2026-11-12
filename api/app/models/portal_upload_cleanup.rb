# frozen_string_literal: true

# Restricted operational intent, deliberately absent from all portal feeds/APIs.
class PortalUploadCleanup < ApplicationRecord
  validates :company_id, :file_key, presence: true
  after_create_commit :enqueue_cleanup

  private

  def enqueue_cleanup
    PortalUploadCleanupJob.perform_later(id)
  rescue StandardError => error
    # The recurring dispatcher recovers after a queue outage.
    Rails.logger.error("Portal upload cleanup enqueue failed: #{error.class.name}")
  end
end
