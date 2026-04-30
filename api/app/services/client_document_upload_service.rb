# frozen_string_literal: true

class ClientDocumentUploadService
  Result = Struct.new(:documents, :uploaded_keys, keyword_init: true)

  def initialize(company_id:, current_user:, params:)
    @company_id = company_id
    @current_user = current_user
    @params = params
    @storage = R2StorageService.new
  end

  def upload!
    files = uploaded_files
    raise ArgumentError, "at least one file is required" if files.empty?

    employee = find_employee!
    validation_errors = validation_errors_for(files)
    raise ActiveRecord::RecordInvalid.new(validation_proxy(validation_errors)) if validation_errors.any?

    uploaded_keys = []
    documents = []

    ClientDocument.transaction do
      files.each do |file|
        file_key = build_file_key(file.original_filename)
        content_type = ClientDocument.detected_content_type(file)
        @storage.upload(file_key, file.tempfile || file, content_type: content_type)
        uploaded_keys << file_key

        documents << ClientDocument.create!(
          company_id: @company_id,
          employee: employee,
          uploaded_by: @current_user,
          title: document_title_for(file, files.count),
          category: @params[:category].presence || "misc",
          file_name: file.original_filename,
          file_key: file_key,
          content_type: content_type,
          file_size: file.size,
          notes: @params[:notes],
          preview_status: ClientDocument.initial_preview_status_for(file),
          visible_to_client: visible_to_client?,
          shared_by_staff: shared_by_staff?
        )
      end
    end

    Result.new(documents: documents, uploaded_keys: uploaded_keys)
  rescue StandardError
    uploaded_keys&.each { |key| @storage.delete(key) }
    raise
  end

  private

  def uploaded_files
    Array.wrap(@params[:files].presence || @params[:file]).compact
  end

  def find_employee!
    return nil if @params[:employee_id].blank?

    Employee.find_by(id: @params[:employee_id], company_id: @company_id).tap do |employee|
      raise ActiveRecord::RecordNotFound, "Employee not found" unless employee
    end
  end

  def validation_errors_for(files)
    files.flat_map do |file|
      ClientDocument.upload_validation_errors(file).map do |message|
        "#{file.original_filename}: #{message}"
      end
    end
  end

  def validation_proxy(validation_errors)
    record = ClientDocument.new
    validation_errors.each { |message| record.errors.add(:file, message) }
    record
  end

  def build_file_key(original_filename)
    sanitized_name = File.basename(original_filename.to_s).gsub(/[^A-Za-z0-9.\-_]/, "_")
    "client_documents/company_#{@company_id}/#{Time.current.strftime('%Y/%m')}/#{SecureRandom.uuid}_#{sanitized_name}"
  end

  def document_title_for(file, total_files)
    return file.original_filename if total_files > 1

    @params[:title].presence || file.original_filename
  end

  def visible_to_client?
    ActiveModel::Type::Boolean.new.cast(@params.fetch(:visible_to_client, true))
  end

  def shared_by_staff?
    @current_user&.admin? || @current_user&.manager? || @current_user&.accountant?
  end
end
