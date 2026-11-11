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
      Rails.logger.error("Rolled back portal upload cleanup failed: #{error.class.name}")
    end
    raise
  end
end
