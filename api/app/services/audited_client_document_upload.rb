# frozen_string_literal: true

class AuditedClientDocumentUpload
  def self.call(company_id:, current_user:, params:)
    result = nil
    ClientDocument.transaction do
      result = ClientDocumentUploadService.new(company_id: company_id, current_user: current_user, params: params).upload!
      yield result
    end
    result
  rescue StandardError => original
    discard_uploaded_keys(company_id, result&.uploaded_keys)
    raise original
  end

  # Any delete failure, including network errors, keeps a retry intent for
  # that key, moves on to the rest, and leaves the caller's error to raise.
  def self.discard_uploaded_keys(company_id, keys)
    Array(keys).each do |key|
      R2StorageService.new.delete(key)
    rescue StandardError => error
      begin
        PortalUploadCleanup.find_or_create_by!(company_id: company_id, file_key: key)
      rescue StandardError => persistence_error
        Rails.logger.error("Portal upload cleanup intent unavailable for #{key}: #{persistence_error.class.name}")
      end
      Rails.logger.error("Rolled back portal upload cleanup scheduled: #{error.class.name}")
    end
  end
end
