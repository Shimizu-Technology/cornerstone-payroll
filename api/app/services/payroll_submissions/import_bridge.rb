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
          unless PayPeriod.portal_submission_runs.exists?(id: @run.id)
            raise ArgumentError, "Only the matching regular pay run offered by the portal can claim this period"
          end
          period.update!(pay_period: @run)
        end
        submission = period.submissions.find(@submission_id)
        current = period.submissions.first
        if submission != current && @superseded_reason.blank?
          raise ArgumentError, "This revision is superseded. Explicitly choose it and record why before opening import review."
        end
        descriptor = portal_descriptor
        documents = source_documents!(submission, descriptor)
        files = documents.map { |link| upload_for!(link, descriptor) }
        linkable_slot = descriptor.files.find(&:supports_link)
        linkable_portal_role = (linkable_slot && descriptor.portal_role_for(linkable_slot.role)) || "changes_workbook"
        link_only = submission.changes_link_url.present? && documents.none? { |link| link.role == linkable_portal_role }
        carried_staff = nil
        if @options[:staff_workbook].present?
          raise ArgumentError, "A staff workbook may only supplement a revision with a workbook link and no workbook file" unless link_only

          validated = FileSet.new(
            company_id: @run.company_id,
            files: [ [ linkable_portal_role, @options[:staff_workbook] ] ],
            descriptor: descriptor
          ).prepare!
          files << validated.prepared.sole.file
        elsif link_only && (carried_staff = staff_workbook_in_review(submission))
          # Reopening the same revision, for example after a worker was
          # reactivated, keeps the workbook staff already attached from the link.
          files << carried_upload!(carried_staff.staff_workbook_document)
        end
        result = PayrollIntake::PreviewService.new(pay_period: @run, source_type: descriptor.key, actor: @actor,
          files: files, portal_documents: documents, portal_submission: submission,
          **@options.slice(:supersedes_package_id, :supersession_reason)).call
        retained_keys = result[:session].documents.filter_map(&:storage_reference) unless result[:duplicate]
        begin
          yield result, submission, current, @superseded_reason, files, carried_staff
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

    def portal_descriptor
      @run.company.portal_submittable_intake_descriptor || PayrollIntake::Registry.fetch("mosa_revel")
    end

    def source_documents!(submission, descriptor)
      links = submission.submission_documents.includes(:client_document).to_a
      roles = links.map(&:role)
      allowed_roles = (descriptor.portal_roles + [ "attachment" ]).uniq

      invalid = (roles - allowed_roles).any? || descriptor.files.any? do |slot|
        portal_role = descriptor.portal_role_for(slot.role)
        next false if portal_role.blank?

        count = roles.count(portal_role)
        max_allowed = slot.max || 1
        must_be_present = portal_role == "revel_payroll" || (slot.required_by_default && !slot.supports_link && slot.waivable.blank?)
        (must_be_present && count.zero?) || count > max_allowed
      end

      if invalid
        if descriptor.key == "mosa_revel"
          raise ArgumentError, "A portal revision needs exactly one Revel PDF and at most one changes workbook"
        end
        raise ArgumentError, "Portal revision files do not match the #{descriptor.label} requirements"
      end

      # Supporting attachments remain evidence, never importer inputs.
      order = descriptor.portal_roles
      links.reject { |link| link.role == "attachment" }.sort_by { |link| order.index(link.role) || order.length }
    end

    # The selection of this revision in the open review that holds a staff-attached workbook.
    def staff_workbook_in_review(submission)
      package = PayrollImport::CurrentReview.source_package_for(@run)
      return unless package&.applyable?

      PayrollSubmissionImport.joins(:payroll_import)
        .where(payroll_submission: submission, payroll_imports: { payroll_intake_session_id: package.id, status: "previewed" })
        .where.not(staff_workbook_document_id: nil)
        .order(id: :desc).first
    end

    # Re-verified against its retained fingerprint before it is used again.
    def carried_upload!(document)
      bytes = PayrollIntake::SourcePackageVerifier.new(session: document.payroll_intake_session).verified_bytes!(document)
      raise ArgumentError, "The staff-attached workbook could not be verified. Attach it again." if bytes.blank?

      tempfile = Tempfile.new([ "portal-import-", File.extname(document.filename.to_s).downcase ])
      @tempfiles << tempfile
      tempfile.binmode
      tempfile.write(bytes)
      tempfile.rewind
      ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: document.filename, type: document.content_type)
    end

    def upload_for!(link, descriptor)
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
      slot = descriptor.file_slot_for_portal_role(link.role)
      valid = if slot
        slot.matches?(filename: link.file_name_snapshot, content_type: document.content_type)
      else
        link.role == "revel_payroll" ? ext == ".pdf" : %w[.xls .xlsx].include?(ext)
      end
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
