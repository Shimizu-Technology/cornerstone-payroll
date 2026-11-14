# frozen_string_literal: true

require "digest"
require "tempfile"

module PayrollSubmissions
  # Reads private retained bytes; never accepts a browser storage key or URL.
  # The importer retains its own independently owned, verified source copy.
  class ImportBridge
    MAX_FILE_BYTES = PayrollIntake::PreviewService::MAX_FILE_BYTES

    def initialize(pay_period:, actor:, submission_id:, superseded_reason: nil, **options)
      @run = pay_period
      @actor = actor
      @submission_id = submission_id
      @superseded_reason = superseded_reason.to_s.strip.presence
      @options = options
      @tempfiles = []
    end

    def call
      # Lock order matches calculation, approval and commit. Submissions take
      # these same locks, so a correction cannot slip between selection/apply.
      Company.find(@run.company_id).with_lock(requires_new: true) do
        @run.lock!
        raise ArgumentError, "Unapprove this pay run before opening portal files in import review" if @run.approved?
        raise ArgumentError, "Cannot import into a non-editable pay period" unless @run.can_edit?
        period = PayrollSubmissionPeriod.lock.find_by!(company_id: @run.company_id, start_date: @run.start_date, end_date: @run.end_date)
        if period.pay_period_id && period.pay_period_id != @run.id
          raise ArgumentError, "This portal period is linked to another pay run"
        end
        unless period.pay_period_id
          catalog = Catalog.new(company: @run.company)
          eligible = catalog.live_pay_period(catalog.resolve(period.id))
          unless eligible&.id == @run.id
            raise ArgumentError, "Only the matching regular pay run offered by the portal can claim this period"
          end
          period.update!(pay_period: @run)
        end
        submission = period.submissions.find(@submission_id)
        current = period.submissions.first
        if submission != current && @superseded_reason.blank?
          raise ArgumentError, "This revision is superseded. Explicitly choose it and record why before opening import review."
        end
        documents = source_documents!(submission)
        files = documents.map { |link| upload_for!(link) }
        if @options[:staff_workbook].present?
          unless submission.changes_link_url.present? && documents.none? { |link| link.role == "changes_workbook" }
            raise ArgumentError, "A staff workbook may only supplement a revision with a workbook link and no workbook file"
          end
          validated = FileSet.new(company_id: @run.company_id, files: [ [ "changes_workbook", @options[:staff_workbook] ] ]).prepare!
          files << validated.prepared.sole.file
        end
        result = PayrollIntake::PreviewService.new(pay_period: @run, source_type: "mosa_revel", actor: @actor,
          files: files, portal_documents: documents,
          **@options.slice(:supersedes_package_id, :supersession_reason)).call
        retained_keys = result[:session].documents.filter_map(&:storage_reference) unless result[:duplicate]
        begin
          yield result, submission, current, @superseded_reason, files
        rescue StandardError
          Array(retained_keys).each do |key|
            R2StorageService.new.delete(key)
          rescue StandardError => error
            Rails.logger.error("Portal intake cleanup failed: #{error.class.name}")
          end
          raise
        end
      end
    ensure
      @tempfiles.each(&:close!)
    end

    private

    def source_documents!(submission)
      links = submission.submission_documents.includes(:client_document).to_a
      roles = links.map(&:role)
      unless roles.count("revel_payroll") == 1 && roles.count("changes_workbook") <= 1 &&
        (roles - PayrollSubmissionDocument::ROLES).empty?
        raise ArgumentError, "A portal revision needs exactly one Revel PDF and at most one changes workbook"
      end
      # Supporting attachments remain evidence, never importer inputs.
      links.reject { |link| link.role == "attachment" }.sort_by { |link| link.role == "revel_payroll" ? 0 : 1 }
    end

    def upload_for!(link)
      document = link.client_document
      unless document.company_id == @run.company_id && document.visible_to_client && !document.archived?
        raise ArgumentError, "Portal source must be visible and unarchived before import"
      end
      document.ensure_usable_for!(:intake)
      size = link.file_size_snapshot.to_i
      raise ArgumentError, "Portal attachment exceeds #{MAX_FILE_BYTES} bytes" if size > MAX_FILE_BYTES
      bytes = R2StorageService.new.download_with_limit(document.file_key, max_bytes: MAX_FILE_BYTES)
      unless bytes.present? && bytes.bytesize <= MAX_FILE_BYTES && bytes.bytesize == size &&
        ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(bytes), link.sha256)
        raise ArgumentError, "Portal source checksum or size does not match its submission snapshot"
      end
      ext = File.extname(link.file_name_snapshot).downcase
      valid = link.role == "revel_payroll" ? ext == ".pdf" : %w[.xls .xlsx].include?(ext)
      raise ArgumentError, "Portal file does not match its source role" unless valid

      tempfile = Tempfile.new([ "portal-import-", ext ])
      @tempfiles << tempfile
      tempfile.binmode
      tempfile.write(bytes)
      tempfile.rewind
      ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: link.file_name_snapshot, type: document.content_type)
    end
  end
end
