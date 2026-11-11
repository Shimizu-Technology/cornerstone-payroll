# frozen_string_literal: true

class AuditedClientDocumentUpload
  def self.call(company_id:, current_user:, params:)
    result = nil
    ClientDocument.transaction do
      result = ClientDocumentUploadService.new(company_id: company_id, current_user: current_user, params: params).upload!
      yield result
    end
    result
  rescue StandardError
    result&.uploaded_keys&.each do |key|
      R2StorageService.new.delete(key)
    rescue R2StorageService::UploadError => error
      begin
        PortalUploadCleanup.find_or_create_by!(company_id: company_id, file_key: key)
      rescue StandardError => persistence_error
        Rails.logger.error("Portal upload cleanup intent unavailable for #{key}: #{persistence_error.class.name}")
      end
      Rails.logger.error("Rolled back portal upload cleanup scheduled: #{error.class.name}")
    end
    raise
  end
end
