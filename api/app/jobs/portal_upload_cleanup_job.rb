# frozen_string_literal: true

class PortalUploadCleanupJob < ApplicationJob
  queue_as :default

  def perform(cleanup_id = nil)
    scope = PortalUploadCleanup.where(completed_at: nil)
    scope = cleanup_id ? scope.where(id: cleanup_id) : scope.limit(100)
    scope.each do |cleanup|
      cleanup.with_lock do
        next if cleanup.completed_at

        cleanup.attempts += 1
        begin
          R2StorageService.new.delete(cleanup.file_key)
          cleanup.completed_at = Time.current
          cleanup.last_error_class = nil
        rescue StandardError => error
          cleanup.last_error_class = error.class.name
        end
        cleanup.save!
      end
    end
  end
end
