# frozen_string_literal: true

require "digest"
require "securerandom"
require "tempfile"

module PayrollIntake
  class PreviewService
    class ReplacementRequiredError < ArgumentError
      attr_reader :current_session

      def initialize(message, current_session:)
        @current_session = current_session
        super(message)
      end
    end

    SOURCE_ADAPTERS = {
      "spike_email" => PayrollIntake::Adapters::SpikeEmail,
      "mosa_revel" => PayrollIntake::Adapters::MosaRevel
    }.freeze

    def self.source_reports_overtime?(source_type)
      adapter = SOURCE_ADAPTERS[source_type.to_s]
      adapter.respond_to?(:reports_overtime?) && adapter.reports_overtime?
    end
    MAX_FILE_BYTES = PayrollIntake::AiExtractor::MAX_FILE_BYTES

    def initialize(pay_period:, source_type:, pasted_text: nil, files: [], actor: nil, storage: nil,
                   supersedes_package_id: nil, supersession_reason: nil, portal_documents: [], portal_submission: nil,
                   carry_forward: false, remove_roles: [])
      @pay_period = pay_period
      @company = pay_period.company
      @source_type = source_type.to_s
      @pasted_text = pasted_text.to_s
      @files = Array(files).compact
      @portal_documents = portal_documents
      @portal_submission = portal_submission
      @actor = actor
      @storage = storage
      @supersedes_package_id = supersedes_package_id.to_s.strip.presence
      @supersession_reason = supersession_reason.to_s.strip.presence
      @carry_forward = carry_forward
      @remove_roles = Array(remove_roles).map(&:to_s)
      @carry_warnings = []
      @carried_tempfiles = []
      @file_snapshots = []
      @stored_references = []
      @retention_committed = false
    end

    def call
      raise ArgumentError, "Cannot import into a committed pay period" unless pay_period.can_edit?
      raise ArgumentError, "Unsupported payroll intake source" unless adapter_class
      unless deterministic_adapter? || (adapter_class.respond_to?(:ai_extraction_instructions) && adapter_class.respond_to?(:ai_extraction_schema))
        raise ArgumentError, "Payroll intake adapter is missing extraction configuration"
      end
      raise ArgumentError, "Payroll intake source is not enabled for this company" unless company.payroll_intake_source_enabled?(source_type)
      raise ArgumentError, "Paste text or upload at least one source file" if pasted_text.blank? && files.empty? && !@carry_forward

      capture_workweek_evidence!

      snapshot_files!
      carry_forward_sources! if @carry_forward
      raise ArgumentError, "Upload at least one source file" if pasted_text.blank? && file_snapshots.empty?
      prepare_portal_revision!
      duplicate = existing_duplicate_session
      return duplicate_session_result(duplicate) if duplicate

      replacement_predecessor!

      extraction = extract_rows
      normalized = normalize_extraction(extraction)
      document_attributes = build_document_attributes

      session = nil
      concurrent_duplicate = nil
      ActiveRecord::Base.transaction do
        pay_period.lock!
        concurrent_duplicate = existing_duplicate_session
        unless concurrent_duplicate
          predecessor = replacement_predecessor!
          predecessor&.mark_superseded!(actor: actor)
          session = PayrollIntakeSession.create!(
            company: company,
            pay_period: pay_period,
            source_type: source_type,
            source_label: adapter_class::SOURCE_LABEL,
            import_hash: import_hash,
            parser_version: adapter_class::PARSER_VERSION,
            package_id: SecureRandom.uuid,
            package_revision: next_package_revision,
            package_schema_version: PayrollIntakeSession::PACKAGE_SCHEMA_VERSION,
            supersedes: predecessor,
            supersession_reason: supersession_reason,
            evidence_snapshot: normalized.fetch(:evidence).merge("workweek" => workweek_evidence)
              .merge(import_hash == source_files_hash ? {} : { "source_import_hash" => source_files_hash })
              .merge(@revision_evidence || {})
              .merge(@source_changes ? { "source_changes" => @source_changes } : {}),
            status: "draft",
            created_by: actor
          )

          persist_documents!(session, document_attributes)

          normalized[:rows].each do |row_attrs|
            session.rows.create!(row_attrs)
          end

          session.mark_previewed!(warnings: normalized[:warnings], totals: normalized[:totals])
          invalidate_prior_calculation!(session, predecessor)
        end
      end

      if concurrent_duplicate
        cleanup_uploaded_sources!
        return duplicate_session_result(concurrent_duplicate)
      end

      @retention_committed = true

      { session: session.reload, duplicate: false }
    rescue ActiveRecord::RecordNotUnique
      cleanup_uploaded_sources!
      duplicate = existing_duplicate_session
      return duplicate_session_result(duplicate) if duplicate

      raise
    rescue StandardError => e
      cleanup_uploaded_sources! unless @retention_committed
      session&.mark_failed!(e.message) if session&.id && PayrollIntakeSession.exists?(session.id)
      raise
    ensure
      @carried_tempfiles.each(&:close!)
    end

    private

    attr_reader :pay_period, :company, :source_type, :pasted_text, :files, :actor, :storage, :file_snapshots,
                :supersedes_package_id, :supersession_reason

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
          content_type: file.content_type.to_s.presence || "application/octet-stream",
          sha256: Digest::SHA256.hexdigest(data)
        }
      end
    end

    # Identifies the source files alone. Client revisions compare against it,
    # so it keeps the formula that earlier packages were stored with.
    def source_files_hash
      @source_files_hash ||= begin
        digest = Digest::SHA256.new
        digest << source_type
        digest << "\n"
        digest << adapter_class::PARSER_VERSION
        digest << "\n"
        digest << JSON.generate(workweek_evidence)
        digest << "\n"
        digest << pasted_text.strip
        file_snapshots.each do |snapshot|
          digest << "\n--file--\n"
          digest << snapshot[:filename]
          digest << snapshot[:content_type]
          digest << snapshot[:sha256]
        end
        digest.hexdigest
      end
    end

    # MoSa matches only active workers. The same files need a new reviewed
    # package after a worker returns, rather than the old unmatched preview.
    # The latest status event keeps a roster that returns to an earlier state
    # from reusing a superseded review.
    def import_hash
      @import_hash ||= if source_type == "mosa_revel"
        roster = JSON.generate(company.employees.active.order(:id).pluck(:id))
        latest_status_event_id = EmployeeStatusEvent.where(company_id: company.id).maximum(:id)
        Digest::SHA256.hexdigest("#{source_files_hash}\n--active-roster--\n#{roster}\n#{latest_status_event_id}")
      else
        source_files_hash
      end
    end

    # File identity remains the default idempotency key. Only a selected newer
    # client revision may replace an applied package with the same source bytes.
    # The new key, predecessor and reason retain the correction as separate evidence.
    def prepare_portal_revision!
      submission = @portal_submission
      return unless submission

      period = submission.period
      # Lock the row without reloading it: a pay-run selection may carry an
      # unsaved period claim that is persisted only on a successful apply.
      PayrollSubmissionPeriod.lock.find(period.id)
      unless submission.company_id == company.id && period.pay_period_id == pay_period.id &&
          period.start_date == pay_period.start_date && period.end_date == pay_period.end_date
        raise ArgumentError, "Portal source and import must belong to the same company and period"
      end
      if submission.submission_imports.where.not(applied_at: nil).exists?
        raise ArgumentError, "This client revision was already applied. Send a newer revision to correct its changes."
      end

      source_hash = source_files_hash
      revision_hash = Digest::SHA256.hexdigest("#{import_hash}\nclient-revision:#{submission.id}")
      if PayrollIntakeSession.exists?(pay_period: pay_period, source_type: source_type, import_hash: revision_hash)
        @import_hash = revision_hash
        return
      end
      current = PayrollIntakeSession.current.find_by(pay_period: pay_period, source_type: source_type)
      same_files = ->(session) { (session.evidence_snapshot["source_import_hash"] || session.import_hash) == source_hash }
      # An earlier changes-only correction may still be an unapplied draft. Walk
      # back through same-file corrections to the package that was applied.
      applied = current
      applied = applied.supersedes while applied && !applied.applied_at && same_files.call(applied) && applied.supersedes
      return unless current && applied&.applied_at && same_files.call(current) && same_files.call(applied)

      prior = PayrollSubmissionImport.joins(:payroll_import)
        .where(payroll_imports: { payroll_intake_session_id: applied.id }).where.not(applied_at: nil)
        .order(id: :desc).first&.payroll_submission
      unless prior && prior.payroll_submission_period_id == period.id && prior.revision < submission.revision &&
          period.current_submission.id == submission.id
        raise ArgumentError, "Identical applied files require a newer current client revision linked to the earlier import."
      end
      if prior.change_rows == submission.change_rows && prior.no_changes == submission.no_changes
        raise ArgumentError, "This client revision repeats the already-applied files and changes. No payroll changes were imported. Send a revision with corrected changes."
      end
      if supersedes_package_id && !supersedes_package_id.in?([ current.id.to_s, current.package_id ])
        raise ReplacementRequiredError.new("The selected source is no longer current. Refresh the review.", current_session: current)
      end

      @import_hash = revision_hash
      @supersedes_package_id = current.package_id
      @supersession_reason = "client revision #{submission.revision}: changes only"
      @revision_evidence = { "source_import_hash" => source_hash, "payroll_submission_id" => submission.id }
    end

    def existing_duplicate_session
      PayrollIntakeSession.find_by(pay_period: pay_period, source_type: source_type, import_hash: import_hash) ||
        legacy_duplicate_session
    end

    # MoSa packages stored before the roster joined the key carry the file-only
    # hash. A plain retry still reuses one until a worker's status changes or
    # a new active worker is added.
    def legacy_duplicate_session
      return if import_hash == source_files_hash || @revision_evidence || @follows_current

      session = PayrollIntakeSession.find_by(pay_period: pay_period, source_type: source_type, import_hash: source_files_hash)
      return unless session
      return if EmployeeStatusEvent.where(company_id: company.id).where("created_at > ?", session.created_at).exists?
      return if company.employees.active.where("created_at > ?", session.created_at).exists?

      session
    end

    def duplicate_session_result(session)
      duplicate_warning = {
        code: "duplicate_source",
        message: session.superseded? ?
          "This exact payroll source is retained as superseded revision #{session.package_revision}. Use the current corrected source." :
          "This exact payroll source has already been previewed for this pay period.",
        severity: session.applied_at.present? || session.superseded? ? "error" : "warning"
      }
      current_warnings = Array(session.warnings)
      session.update!(warnings: [ duplicate_warning, *current_warnings ].uniq { |warning| warning["code"] || warning[:code] })
      { session: session.reload, duplicate: true }
    end

    def latest_current_package
      PayrollIntakeSession.current
                          .where(pay_period: pay_period, source_type: source_type)
                          .order(package_revision: :desc, id: :desc)
                          .first
    end

    # A source's files can arrive separately. The new package keeps every file
    # of the current package that was not uploaded again, re-verified against
    # its retained fingerprint and stored as this package's own copy. Adding a
    # missing file, or matching the same files again after the roster changed,
    # completes an unapplied package without a typed reason. A file whose bytes
    # differ from one already received is a correction and still needs one.
    def carry_forward_sources!
      current = latest_current_package
      return unless current

      known_roles = PayrollIntake::SourceCompleteness.roles_for(source_type).keys
      uploaded_roles = file_snapshots.map { |snapshot| snapshot_role(snapshot) }
      existing = current.documents.in_package_order.select do |document|
        document.source_role.in?(known_roles) && document.verification_status != "legacy_unverified"
      end
      carried = existing.reject { |document| document.source_role.in?(uploaded_roles + @remove_roles) }
      removed = existing.map(&:source_role) & @remove_roles
      # A file saved before files were fingerprinted cannot be re-verified, so
      # it is not carried. Say so, rather than quietly dropping it.
      unverified = current.documents.in_package_order.select do |document|
        document.source_role.in?(known_roles) && document.verification_status == "legacy_unverified" &&
          !document.source_role.in?(uploaded_roles + @remove_roles)
      end
      completeness = PayrollIntake::SourceCompleteness.new(session: current, company: company)
      unverified_labels = completeness.labels_for(unverified.map(&:source_role).uniq)
      if unverified_labels.any?
        @carry_warnings << {
          code: "unverified_source_not_kept",
          message: "The #{unverified_labels.to_sentence} in import version #{current.package_revision} was saved before files were " \
                   "verified, so it was not kept in this version. Upload it again.",
          severity: "warning"
        }
      end
      verifier = PayrollIntake::SourcePackageVerifier.new(session: current, storage: storage_service)
      carried_snapshots = carried.map { |document| carried_snapshot(document, verifier.verified_bytes!(document)) }
      replaced = file_snapshots.filter_map do |snapshot|
        document = existing.find { |candidate| candidate.source_role == snapshot_role(snapshot) }
        document.source_role if document && document.sha256 != snapshot[:sha256]
      end
      added = uploaded_roles - existing.map(&:source_role)

      # Package order stays the same however the files arrived, so a package
      # completed in two steps has the same identity as one uploaded at once.
      @file_snapshots = (file_snapshots + carried_snapshots).each_with_index
        .sort_by { |snapshot, index| [ known_roles.index(snapshot_role(snapshot)) || known_roles.length, index ] }
        .map(&:first)
      @files = file_snapshots.map { |snapshot| snapshot[:file] }
      @source_changes = {
        "added" => added, "replaced" => replaced, "removed" => removed,
        "not_kept_unverified" => unverified.map { |document| { "role" => document.source_role, "document_id" => document.id } },
        "carried" => carried.map { |document| { "role" => document.source_role, "document_id" => document.id, "sha256" => document.sha256 } }
      }

      return unless current.applyable? && replaced.empty?
      return if supersedes_package_id.present? && !supersedes_package_id.in?([ current.id.to_s, current.package_id ])

      @supersedes_package_id = current.package_id
      @supersession_reason ||= [
        added.any? ? "Added: #{completeness.labels_for(added).to_sentence}" : "Matched the same files again after the employee list changed",
        unverified_labels.any? ? "Not kept (saved before files were verified): #{unverified_labels.to_sentence}" : nil
      ].compact.join(". ")
      follow_current_package!(current)
    end

    # Adding or removing a file can return to the exact files of a superseded
    # version, which can no longer be applied. Those files then become a new
    # version after the current one instead of matching the old version.
    def follow_current_package!(current)
      return if @portal_submission

      earlier = PayrollIntakeSession.find_by(pay_period: pay_period, source_type: source_type, import_hash: import_hash)
      return unless earlier&.superseded?

      # The current version may already be these same files following its
      # predecessor. Reuse it, so a retry doesn't create version after version.
      if current.supersedes && current.import_hash == Digest::SHA256.hexdigest("#{import_hash}\nafter-package:#{current.supersedes.package_id}")
        @import_hash = current.import_hash
        return
      end

      @follows_current = true
      @import_hash = Digest::SHA256.hexdigest("#{import_hash}\nafter-package:#{current.package_id}")
    end

    def carried_snapshot(document, data)
      tempfile = Tempfile.new([ "payroll-intake-source", File.extname(document.filename.to_s) ])
      @carried_tempfiles << tempfile
      tempfile.binmode
      tempfile.write(data)
      tempfile.rewind
      {
        file: ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: document.filename, type: document.content_type),
        data: data,
        filename: document.filename,
        content_type: document.content_type,
        sha256: Digest::SHA256.hexdigest(data),
        carried_from_document_id: document.id,
        portal_document: document.payroll_submission_document
      }
    end

    def snapshot_role(snapshot)
      source_role_for(filename: snapshot[:filename], content_type: snapshot[:content_type], position: 0, pasted: false)
    end

    def replacement_predecessor!
      current = latest_current_package
      if current.blank?
        if supersedes_package_id.present?
          raise ArgumentError, "The source package selected for replacement is no longer current. Refresh and review the latest package."
        end
        return nil
      end

      unless supersedes_package_id.present?
        raise ReplacementRequiredError.new(
          "A current source package already exists. Confirm that this corrected source replaces revision #{current.package_revision} and enter the reason for the change.",
          current_session: current
        )
      end
      unless supersedes_package_id.in?([ current.id.to_s, current.package_id ])
        raise ReplacementRequiredError.new(
          "Revision #{current.package_revision} is now the current source. Refresh and confirm that your corrected source replaces it.",
          current_session: current
        )
      end
      if supersession_reason.blank?
        raise ReplacementRequiredError.new(
          "Enter why this corrected source replaces revision #{current.package_revision}.",
          current_session: current
        )
      end

      current
    end

    def invalidate_prior_calculation!(session, predecessor)
      return if pay_period.draft? && !pay_period.intake_stale? && predecessor&.applied_at.blank?

      reason = if predecessor.present?
        "Source revision #{session.package_revision} replaced revision #{predecessor.package_revision}: #{supersession_reason}"
      else
        "Source revision #{session.package_revision} was received after payroll calculation began."
      end

      pay_period.mark_intake_stale!(
        session: session,
        reason: reason
      )
    end

    def normalize_extraction(extraction)
      normalized = adapter_class.new(pay_period: pay_period, company: company).normalize(
        extracted_rows: extraction[:rows],
        detected_period: extraction[:detected_period]
      )
      warnings = Array(extraction[:warnings]) + Array(normalized[:warnings]) + @carry_warnings
      if workweek_evidence["aligned_with_pay_period"] == false
        warnings << {
          code: "pay_period_workweek_offset",
          message: "This pay period starts on a different day than the client's saved overtime workweek. " \
                   "Overtime is used exactly as the source reports it. Update the workweek in Cornerstone if it is wrong.",
          severity: "warning"
        }
      end

      if normalized[:rows].empty?
        warnings << { code: "no_rows_detected", message: "No payroll rows were detected. Paste a clearer table or upload a clearer screenshot.", severity: "warning" }
      end

      normalized.merge(warnings: warnings)
    end

    def capture_workweek_evidence!
      @workweek_evidence = PayrollIntake::WorkweekEvidence.new(
        pay_period: pay_period, allow_misaligned: self.class.source_reports_overtime?(source_type)
      ).capture!
    end

    def workweek_evidence
      @workweek_evidence || capture_workweek_evidence!
    end

    def build_document_attributes
      attributes = []
      if pasted_text.present?
        source_bytes = pasted_text.b
        attributes << {
          document_type: "pasted_text",
          source_role: source_role_for(filename: "pasted-text.txt", content_type: "text/plain", position: attributes.length, pasted: true),
          position: attributes.length,
          text_content: pasted_text,
          byte_size: source_bytes.bytesize,
          sha256: Digest::SHA256.hexdigest(source_bytes),
          verification_status: "verified",
          verified_at: Time.current,
          metadata: { character_count: pasted_text.length }
        }
      end

      attributes.concat(uploaded_document_attributes(starting_position: attributes.length))
    end

    def uploaded_document_attributes(starting_position:)
      document_uuid = SecureRandom.uuid
      file_snapshots.map.with_index do |snapshot, index|
        key = StagingStoragePolicy.new_key("payroll-intake/#{company.id}/#{pay_period.id}/#{document_uuid}/#{index}-#{snapshot[:filename]}")
        @stored_references << key
        storage_service.upload(key, snapshot[:data], content_type: snapshot[:content_type])
        verify_retained_source!(key, snapshot)
        {
          payroll_submission_document: snapshot[:portal_document] || @portal_documents[index],
          document_type: document_type_for(snapshot),
          source_role: source_role_for(
            filename: snapshot[:filename],
            content_type: snapshot[:content_type],
            position: starting_position + index,
            pasted: false
          ),
          position: starting_position + index,
          filename: snapshot[:filename],
          content_type: snapshot[:content_type],
          storage_reference: key,
          byte_size: snapshot[:data].bytesize,
          sha256: snapshot[:sha256],
          verification_status: "verified",
          verified_at: Time.current,
          metadata: { bytes: snapshot[:data].bytesize, carried_from_document_id: snapshot[:carried_from_document_id] }.compact
        }
      end
    end

    def persist_documents!(session, document_attributes)
      document_attributes.each do |attributes|
        session.documents.create!(attributes)
      end
    end

    def extract_rows
      if deterministic_adapter?
        return adapter_class.new(pay_period: pay_period, company: company).extract(files: files, pasted_text: pasted_text)
      end

      text_extraction = extract_rows_from_text
      return text_extraction if text_extraction[:rows].present?

      ai_extraction = PayrollIntake::AiExtractor.new(
        source_type: source_type,
        adapter: adapter_class,
        text: pasted_text,
        files: files
      ).call
      {
        rows: ai_extraction[:rows],
        detected_period: ai_extraction[:detected_period] || text_extraction[:detected_period],
        warnings: Array(text_extraction[:warnings]) + Array(ai_extraction[:warnings])
      }
    end

    def extract_rows_from_text
      parser_class = adapter_class.respond_to?(:text_parser_class) ? adapter_class.text_parser_class : nil
      return empty_extraction unless pasted_text.present? && parser_class

      parser_class.new(pasted_text).call
    end

    def empty_extraction
      { rows: [], warnings: [], detected_period: nil }
    end

    def storage_service
      @storage ||= R2StorageService.new
    end

    def verify_retained_source!(key, snapshot)
      retained = storage_service.download_with_limit(key, max_bytes: MAX_FILE_BYTES)
      valid = retained.present? && retained.bytesize == snapshot[:data].bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(retained), snapshot[:sha256])
      return if valid

      raise R2StorageService::UploadError, "Payroll source could not be verified after upload"
    end

    def cleanup_uploaded_sources!
      @stored_references.each do |key|
        storage_service.delete(key)
      rescue StandardError => e
        Rails.logger.error("Payroll intake source cleanup failed for #{key}: #{e.class}: #{e.message}")
      end
      @stored_references.clear
    end

    def next_package_revision
      PayrollIntakeSession.where(pay_period: pay_period).maximum(:package_revision).to_i + 1
    end

    def document_type_for(snapshot)
      content_type = snapshot[:content_type]
      return "pdf" if content_type == "application/pdf" || File.extname(snapshot[:filename]).casecmp(".pdf").zero?
      return "image" if content_type.start_with?("image/")

      "other"
    end

    def deterministic_adapter?
      adapter_class&.instance_methods(false)&.include?(:extract)
    end

    def source_role_for(filename:, content_type:, position:, pasted:)
      return "pasted_email" if pasted
      return "email_attachment" unless adapter_class.respond_to?(:source_role_for)

      adapter_class.source_role_for(filename: filename, content_type: content_type, position: position)
    end

    def sanitize_filename(filename)
      filename.gsub(/[^a-zA-Z0-9.\-_]+/, "-").presence || "upload"
    end
  end
end
