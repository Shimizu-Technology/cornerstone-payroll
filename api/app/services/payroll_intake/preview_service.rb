# frozen_string_literal: true

require "digest"
require "securerandom"

module PayrollIntake
  class PreviewService
    SOURCE_ADAPTERS = {
      "spike_email" => PayrollIntake::Adapters::SpikeEmail
    }.freeze
    MAX_FILE_BYTES = PayrollIntake::AiExtractor::MAX_FILE_BYTES

    def initialize(pay_period:, source_type:, pasted_text: nil, files: [], actor: nil, storage: nil)
      @pay_period = pay_period
      @company = pay_period.company
      @source_type = source_type.to_s
      @pasted_text = pasted_text.to_s
      @files = Array(files).compact
      @actor = actor
      @storage = storage
      @file_snapshots = []
    end

    def call
      raise ArgumentError, "Cannot import into a committed pay period" unless pay_period.can_edit?
      raise ArgumentError, "Unsupported payroll intake source" unless adapter_class
      raise ArgumentError, "Payroll intake source is not enabled for this company" unless company.payroll_intake_source_enabled?(source_type)
      raise ArgumentError, "Paste text or upload at least one source file" if pasted_text.blank? && files.empty?

      snapshot_files!
      duplicate = existing_duplicate_session
      return duplicate_session_result(duplicate) if duplicate

      session = nil
      ActiveRecord::Base.transaction do
        session = PayrollIntakeSession.create!(
          company: company,
          pay_period: pay_period,
          source_type: source_type,
          source_label: adapter_class::SOURCE_LABEL,
          import_hash: import_hash,
          parser_version: adapter_class::PARSER_VERSION,
          status: "draft",
          created_by: actor
        )

        persist_documents!(session)

        extraction = extract_rows
        normalized = adapter_class.new(pay_period: pay_period, company: company).normalize(
          extracted_rows: extraction[:rows],
          detected_period: extraction[:detected_period]
        )
        warnings = Array(extraction[:warnings]) + normalized[:warnings]

        normalized[:rows].each do |row_attrs|
          session.rows.create!(row_attrs)
        end

        if normalized[:rows].empty?
          warnings << { code: "no_rows_detected", message: "No payroll rows were detected. Paste a clearer table or upload a clearer screenshot.", severity: "warning" }
        end

        session.mark_previewed!(warnings: warnings, totals: normalized[:totals])
      end

      { session: session.reload, duplicate: false }
    rescue StandardError => e
      session&.mark_failed!(e.message) if session&.persisted?
      raise
    end

    private

    attr_reader :pay_period, :company, :source_type, :pasted_text, :files, :actor, :storage, :file_snapshots

    def adapter_class
      SOURCE_ADAPTERS[source_type]
    end

    def snapshot_files!
      @file_snapshots = files.map do |file|
        io = file.tempfile || file
        io.rewind if io.respond_to?(:rewind)
        data = io.read(MAX_FILE_BYTES + 1) || ""
        raise ArgumentError, "Attachment exceeds #{MAX_FILE_BYTES} bytes" if data.bytesize > MAX_FILE_BYTES

        io.rewind if io.respond_to?(:rewind)
        {
          file: file,
          data: data,
          filename: sanitize_filename(file.original_filename.to_s.presence || "upload"),
          content_type: file.content_type.to_s.presence || "application/octet-stream"
        }
      end
    end

    def import_hash
      @import_hash ||= begin
        digest = Digest::SHA256.new
        digest << source_type
        digest << "\n"
        digest << pasted_text.strip
        file_snapshots.each do |snapshot|
          digest << "\n--file--\n"
          digest << snapshot[:filename]
          digest << snapshot[:content_type]
          digest << Digest::SHA256.hexdigest(snapshot[:data].to_s)
        end
        digest.hexdigest
      end
    end

    def existing_duplicate_session
      PayrollIntakeSession.find_by(pay_period: pay_period, source_type: source_type, import_hash: import_hash)
    end

    def duplicate_session_result(session)
      duplicate_warning = {
        code: "duplicate_source",
        message: "This exact payroll source has already been previewed for this pay period.",
        severity: session.applied_at.present? ? "error" : "warning"
      }
      current_warnings = Array(session.warnings)
      session.update!(warnings: [ duplicate_warning, *current_warnings ].uniq { |warning| warning["code"] || warning[:code] })
      { session: session.reload, duplicate: true }
    end

    def persist_documents!(session)
      if pasted_text.present?
        session.documents.create!(
          document_type: "pasted_text",
          text_content: pasted_text,
          metadata: { character_count: pasted_text.length }
        )
      end

      document_uuid = SecureRandom.uuid
      file_snapshots.each_with_index do |snapshot, index|
        key = "payroll-intake/#{company.id}/#{pay_period.id}/#{document_uuid}/#{index}-#{snapshot[:filename]}"
        uploaded_url = storage_service.upload(key, snapshot[:data], content_type: snapshot[:content_type])
        session.documents.create!(
          document_type: document_type_for(snapshot),
          filename: snapshot[:filename],
          content_type: snapshot[:content_type],
          storage_reference: key,
          metadata: { bytes: snapshot[:data].bytesize, uploaded_url: uploaded_url }
        )
      end
    end

    def extract_rows
      text_extraction = pasted_text.present? ? PayrollIntake::SpikeEmailTextParser.new(pasted_text).call : { rows: [], warnings: [], detected_period: nil }
      return text_extraction if text_extraction[:rows].present?

      ai_extraction = PayrollIntake::AiExtractor.new(source_type: source_type, text: pasted_text, files: files).call
      {
        rows: ai_extraction[:rows],
        detected_period: ai_extraction[:detected_period] || text_extraction[:detected_period],
        warnings: Array(text_extraction[:warnings]) + Array(ai_extraction[:warnings])
      }
    end

    def storage_service
      @storage ||= R2StorageService.new
    end

    def document_type_for(snapshot)
      content_type = snapshot[:content_type]
      return "pdf" if content_type == "application/pdf" || File.extname(snapshot[:filename]).casecmp(".pdf").zero?
      return "image" if content_type.start_with?("image/")

      "other"
    end

    def sanitize_filename(filename)
      filename.gsub(/[^a-zA-Z0-9.\-_]+/, "-").presence || "upload"
    end
  end
end
