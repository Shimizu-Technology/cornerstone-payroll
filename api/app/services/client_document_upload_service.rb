# frozen_string_literal: true

require "digest"

class ClientDocumentUploadService
  MAX_FILES = 10
  MAX_TOTAL_BYTES = 50.megabytes
  Result = Struct.new(:documents, :uploaded_keys, :document_requirement, :replayed, keyword_init: true)

  # A retry key reused for a different set of files or details.
  class RetryConflict < StandardError; end

  def initialize(company_id:, current_user:, params:)
    @company_id = company_id
    @current_user = current_user
    @params = params
    @storage = R2StorageService.new
  end

  def upload!
    files = uploaded_files
    raise ArgumentError, "at least one file is required" if files.empty?

    raise ArgumentError, "Choose no more than 10 files at a time." if files.size > MAX_FILES
    unless files.all? { |file| file.respond_to?(:tempfile) && file.respond_to?(:original_filename) && file.respond_to?(:content_type) }
      raise ArgumentError, "Please choose files from your device and try again."
    end
    if files.sum { |file| file.size.to_i } > MAX_TOTAL_BYTES
      raise ArgumentError, "These files total more than 50 MB. Please upload them in smaller groups."
    end

    employee = find_employee!
    document_requirement = find_document_requirement!(employee, files)
    validation_errors = validation_errors_for(files)
    raise ActiveRecord::RecordInvalid.new(validation_proxy(validation_errors)) if validation_errors.any?

    fingerprint = upload_fingerprint(files) if upload_key
    if (saved = saved_upload(fingerprint, files.size))
      return Result.new(documents: saved, uploaded_keys: [], document_requirement: nil, replayed: true)
    end

    uploaded_keys = []
    documents = []
    prepared_uploads = files.map do |file|
      file_key = build_file_key(file.original_filename)
      content_type = @validated_types.fetch(file.object_id)
      @storage.upload(file_key, file.tempfile || file, content_type: content_type)
      uploaded_keys << file_key
      { file: file, file_key: file_key, content_type: content_type }
    end

    replayed = nil
    ClientDocument.transaction do
      if upload_key
        # Serializes simultaneous retries; the first one to commit wins.
        User.lock.find(@current_user.id)
        replayed = saved_upload(fingerprint, files.size)
        next if replayed
      end
      if document_requirement
        Company.lock.find(@company_id)
        employee = find_employee!
        document_requirement = find_document_requirement!(employee, files)
      end

      prepared_uploads.each_with_index do |prepared_upload, position|
        file = prepared_upload.fetch(:file)
        documents << ClientDocument.create!(
          company_id: @company_id,
          employee: employee,
          uploaded_by: @current_user,
          title: document_title_for(file, files.count),
          category: @params[:category].presence || "misc",
          file_name: file.original_filename,
          file_key: prepared_upload.fetch(:file_key),
          content_type: prepared_upload.fetch(:content_type),
          file_size: file.size,
          scan_status: ClientDocumentScanner.adapter.initial_status,
          notes: @params[:notes],
          preview_status: ClientDocument.initial_preview_status_for(file),
          visible_to_client: visible_to_client?,
          shared_by_staff: shared_by_staff?,
          upload_idempotency_key: upload_key,
          upload_request_fingerprint: fingerprint,
          upload_position: (position if upload_key),
          uploaded_for_message: uploaded_for_message?
        )
      end

      if document_requirement
        document_requirement.with_lock do
          prior_status = document_requirement.status
          document_requirement.update!(
            client_document: documents.first,
            status: "received",
            received_at: Time.current,
            reviewed_by: nil,
            reviewed_at: nil,
            review_note: nil
          )
          document_requirement.events.create!(
            company: document_requirement.company,
            employee: document_requirement.employee,
            client_document: documents.first,
            document_title: documents.first.title,
            actor: @current_user,
            event_type: "document_received",
            from_status: prior_status,
            to_status: "received"
          )
        end
      end
    end

    if replayed
      AuditedClientDocumentUpload.discard_uploaded_keys(@company_id, uploaded_keys)
      return Result.new(documents: replayed, uploaded_keys: [], document_requirement: nil, replayed: true)
    end

    Result.new(documents: documents, uploaded_keys: uploaded_keys, document_requirement: document_requirement, replayed: false)
  rescue StandardError
    uploaded_keys&.each { |key| @storage.delete(key) }
    raise
  end

  private

  def upload_key
    return @upload_key if defined?(@upload_key)

    key = @params[:upload_key].presence&.to_s
    raise ArgumentError, "The upload retry key is too long." if key && key.length > 128

    @upload_key = key
  end

  # Files saved by an earlier request with this retry key, or nil. A replay
  # is only reported when every file of that request is still there.
  def saved_upload(fingerprint, expected_count)
    return nil unless upload_key

    saved = ClientDocument.where(company_id: @company_id, uploaded_by_id: @current_user.id, upload_idempotency_key: upload_key)
      .includes(:employee, :uploaded_by).order(:upload_position).to_a
    return nil if saved.empty?
    raise RetryConflict, "This upload retry key was used for different files." unless saved.all? { |document| document.upload_request_fingerprint == fingerprint }
    unless saved.map(&:upload_position) == (0...expected_count).to_a
      raise RetryConflict, "Some files from this upload were removed since it was saved. Choose the files again to upload them."
    end

    saved
  end

  # The files' names, sizes and bytes plus the details that shape the records.
  def upload_fingerprint(files)
    parts = files.map do |file|
      io = file.tempfile || file
      digest = Digest::SHA256.new
      io.rewind
      while (chunk = io.read(1.megabyte))
        digest << chunk
      end
      io.rewind
      [ file.original_filename.to_s, file.size.to_i, digest.hexdigest ]
    end
    details = [ @params[:category].presence || "misc", @params[:employee_id].presence&.to_s, @params[:title].presence, @params[:notes].presence, visible_to_client?, @params[:requirement_id].presence&.to_s, uploaded_for_message? ]
    Digest::SHA256.hexdigest(JSON.generate([ parts, details ]))
  end

  def uploaded_files
    Array.wrap(@params[:files].presence || @params[:file]).compact
  end

  def find_employee!
    return nil if @params[:employee_id].blank?

    Employee.find_by(id: @params[:employee_id], company_id: @company_id).tap do |employee|
      raise ActiveRecord::RecordNotFound, "Employee not found" unless employee
    end
  end

  def find_document_requirement!(employee, files)
    return nil if @params[:requirement_id].blank?
    raise ArgumentError, "choose one file when attaching it to a readiness item" unless files.one?
    raise ActiveRecord::RecordNotFound, "Employee not found" unless employee

    EmployeeDocumentRequirement.find_by(
      id: @params[:requirement_id],
      company_id: @company_id,
      employee_id: employee.id
    ) || raise(ActiveRecord::RecordNotFound, "Document requirement not found")
  end

  def validation_errors_for(files)
    @validated_types = {}
    files.filter_map do |file|
      @validated_types[file.object_id] = ClientDocumentFileValidator.new(file).validate!
      nil
    rescue ClientDocumentFileValidator::InvalidFile => e
      "#{file.original_filename}: #{e.message}"
    end
  end

  def validation_proxy(validation_errors)
    record = ClientDocument.new
    validation_errors.each { |message| record.errors.add(:file, message) }
    record
  end

  def build_file_key(original_filename)
    sanitized_name = File.basename(original_filename.to_s).gsub(/[^A-Za-z0-9.\-_]/, "_")
    StagingStoragePolicy.new_key("client_documents/company_#{@company_id}/#{Time.current.strftime('%Y/%m')}/#{SecureRandom.uuid}_#{sanitized_name}")
  end

  def document_title_for(file, total_files)
    return file.original_filename if total_files > 1

    @params[:title].presence || file.original_filename
  end

  # Uploaded in a message composer. The message, not a separate upload row,
  # represents it in the Client Inbox once it is sent.
  def uploaded_for_message?
    ActiveModel::Type::Boolean.new.cast(@params[:for_message]) == true
  end

  def visible_to_client?
    ActiveModel::Type::Boolean.new.cast(@params.fetch(:visible_to_client, true))
  end

  def shared_by_staff?
    @current_user&.staff_member?
  end
end
