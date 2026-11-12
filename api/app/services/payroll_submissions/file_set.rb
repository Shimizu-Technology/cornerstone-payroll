# frozen_string_literal: true

require "digest"

module PayrollSubmissions
  # Validates and fingerprints uploaded files before anything is stored, then
  # stores them as client documents inside the caller's transaction. Reuses
  # the portal's upload validation; payroll source files keep the importer's
  # 8 MiB limit so they stay usable for the later import bridge.
  class FileSet
    SOURCE_FILE_LIMIT = 8.megabytes
    MAX_FILES = 10
    MAX_TOTAL_BYTES = ClientDocumentUploadService::MAX_TOTAL_BYTES
    WORKBOOK_TYPES = %w[
      application/vnd.ms-excel
      application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
      text/csv
    ].freeze

    Prepared = Struct.new(:role, :file, :sha256, :content_type, :file_key, keyword_init: true)

    class Invalid < StandardError
      attr_reader :details

      def initialize(details)
        @details = details
        super(details.values.flatten.first)
      end
    end

    attr_reader :prepared, :uploaded_keys

    # files: [[role, uploaded_file], ...]
    def initialize(company_id:, files:)
      @company_id = company_id
      @files = files
      @uploaded_keys = []
      @prepared = []
    end

    def prepare!
      errors = Hash.new { |hash, key| hash[key] = [] }
      if @files.size > MAX_FILES
        raise Invalid, { "files" => [ "Choose no more than #{MAX_FILES} files at a time." ] }
      end
      if @files.sum { |_role, file| file.respond_to?(:size) ? file.size.to_i : 0 } > MAX_TOTAL_BYTES
        raise Invalid, { "files" => [ "These files total more than 50 MB. Send fewer files and add the rest in a message." ] }
      end

      @prepared = @files.filter_map do |role, file|
        unless file.respond_to?(:tempfile) && file.respond_to?(:original_filename)
          errors[role] << "Choose a file from your device and try again."
          next
        end
        content_type = ClientDocumentFileValidator.new(file).validate!
        role_error = role_error(role, content_type, file)
        if role_error
          errors[role] << "#{file.original_filename}: #{role_error}"
          next
        end
        Prepared.new(role: role, file: file, sha256: sha256_for(file), content_type: content_type)
      rescue ClientDocumentFileValidator::InvalidFile => error
        errors[role] << "#{file.original_filename}: #{error.message}"
        nil
      end
      raise Invalid, errors.to_h if errors.any?

      self
    end

    # [[role, sha256, file name]] for retry fingerprints.
    def fingerprint_parts
      @prepared.map { |item| [ item.role, item.sha256, item.file.original_filename ] }
    end

    # Call outside any database lock: storage is network I/O.
    def upload!
      storage = R2StorageService.new
      @prepared.each do |item|
        key = StagingStoragePolicy.new_key("client_documents/company_#{@company_id}/#{Time.current.strftime('%Y/%m')}/#{SecureRandom.uuid}_#{safe_name(item.file.original_filename)}")
        # Recorded before the write: a failure part-way through an upload
        # still leaves the key for discard! (and its cleanup intent) to remove.
        @uploaded_keys << key
        item.file_key = key
        storage.upload(key, item.file.tempfile, content_type: item.content_type)
      end
      self
    end

    def create_document!(item, actor:, title:, category:, visible_to_client:)
      ClientDocument.create!(
        company_id: @company_id, uploaded_by: actor, title: title.first(250), category: category,
        file_name: item.file.original_filename, file_key: item.file_key, content_type: item.content_type,
        file_size: item.file.size, scan_status: ClientDocumentScanner.adapter.initial_status,
        preview_status: ClientDocument.initial_preview_status_for(item.file),
        visible_to_client: visible_to_client, shared_by_staff: actor.staff_member?
      )
    end

    def discard!
      AuditedClientDocumentUpload.discard_uploaded_keys(@company_id, @uploaded_keys)
      @uploaded_keys = []
    end

    private

    def role_error(role, content_type, file)
      case role
      when "revel_payroll", "paycheck", "direct_deposit"
        return "must be a PDF" unless content_type == "application/pdf"
      when "changes_workbook"
        return "must be an Excel workbook or CSV file" unless WORKBOOK_TYPES.include?(content_type)
      end
      return "must be 8 MB or smaller" if %w[revel_payroll changes_workbook].include?(role) && file.size.to_i > SOURCE_FILE_LIMIT

      nil
    end

    def sha256_for(file)
      io = file.tempfile
      io.rewind
      digest = Digest::SHA256.new
      while (chunk = io.read(1.megabyte))
        digest.update(chunk)
      end
      io.rewind
      digest.hexdigest
    end

    def safe_name(name)
      File.basename(name.to_s).gsub(/[^A-Za-z0-9.\-_]/, "_")
    end
  end
end
