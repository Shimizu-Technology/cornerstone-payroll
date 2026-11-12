# frozen_string_literal: true

require "digest"

module PayrollSubmissions
  # A client sends (or corrects) a period's package. Every send is a new
  # numbered revision; earlier revisions and their files are kept. A retry
  # with the same key replays the saved revision, and an identical package
  # (same file checksums and answers) returns the current revision instead
  # of adding a duplicate.
  class CreateRevision
    Result = Struct.new(:submission, :outcome, keyword_init: true) # outcome: :created, :replayed, :duplicate

    class Conflict < StandardError; end
    class Closed < StandardError; end

    def initialize(company:, actor:, entry:, catalog:, params:, request_context: {})
      @company = company
      @actor = actor
      @entry = entry
      @catalog = catalog
      @params = params
      @request_context = request_context
    end

    def call
      raise Closed, "This period opens for files on #{@entry.end_date.strftime('%b %-d, %Y')}." unless @catalog.open_for_files?(@entry)

      key = @params[:idempotency_key].presence&.to_s
      raise FileSet::Invalid, { "idempotency_key" => [ "is too long" ] } if key && key.length > 128

      answers = normalized_answers
      files = FileSet.new(company_id: @company.id, files: incoming_files).prepare!
      keep_ids = keep_document_ids
      request_fingerprint = fingerprint(dates: [ @entry.start_date, @entry.end_date ], answers: answers, keep: keep_ids,
        files: files.prepared.map { |item| [ item.role, item.sha256, item.file.original_filename ] }, based_on: @params[:based_on_revision].presence)

      if key && @entry.record && (existing = @entry.record.submissions.find_by(submitted_by_id: @actor.id, idempotency_key: key))
        return replay(existing, request_fingerprint)
      end

      current = @entry.record&.current_submission
      kept = kept_documents(current, keep_ids)
      content = content_fingerprint(answers, kept.map { |doc| [ doc.role, doc.sha256 ] } + files.prepared.map { |item| [ item.role, item.sha256 ] })
      return Result.new(submission: current, outcome: :duplicate) if current && current.content_fingerprint == content

      validate_roles!(kept, files.prepared, no_changes: answers[:no_changes])
      files.upload!
      submission = nil
      outcome = :created
      PayrollSubmissionPeriod.transaction do
        @company.lock!
        run = @catalog.live_pay_period(@entry)
        run&.lock!
        period = @catalog.materialize!(@entry)
        period.lock!
        if key && (existing = period.submissions.find_by(submitted_by_id: @actor.id, idempotency_key: key))
          submission = existing
          outcome = :replayed
          raise ActiveRecord::Rollback
        end
        raise PayrollSubmissionPeriod::TransitionError, "This period is paid. Send any correction as a message." if period.status == "paid"

        latest = period.submissions.reload.first
        if latest && latest.content_fingerprint == content
          submission = latest
          outcome = :duplicate
          raise ActiveRecord::Rollback
        end
        # A correction must name the revision it replaces, so a client working
        # from an older revision cannot silently become current.
        if latest && latest.revision.to_s != @params[:based_on_revision].to_s
          raise Conflict, "A newer revision was sent while you were working. Reload to see it, then send your update."
        end
        kept = kept_documents(latest, keep_ids)

        submission = period.submissions.create!(
          company_id: @company.id, revision: (latest&.revision || 0) + 1, submitted_by: @actor,
          submitted_by_name_snapshot: @actor.name, submitted_at: Time.current,
          no_changes: answers[:no_changes], change_rows: answers[:change_rows], changes_link_url: answers[:changes_link_url],
          notes: answers[:notes], content_fingerprint: content, request_fingerprint: request_fingerprint, idempotency_key: key
        )
        # Revel PDF first, then the workbook, then attachments, kept and new alike.
        rank = PayrollSubmissionDocument::ROLES.each_with_index.to_h
        entries = kept.map { |previous| [ :kept, previous ] } + files.prepared.map { |item| [ :new, item ] }
        new_documents = []
        entries.sort_by.with_index { |(_, item), index| [ rank.fetch(item.role), index ] }.each.with_index(1) do |(kind, item), position|
          if kind == :kept
            submission.submission_documents.create!(company_id: @company.id, client_document_id: item.client_document_id,
              role: item.role, position: position, sha256: item.sha256,
              file_name_snapshot: item.file_name_snapshot, file_size_snapshot: item.file_size_snapshot)
          else
            document = files.create_document!(item, actor: @actor, title: title_for(item, period, submission.revision),
              category: "payroll_source", visible_to_client: true)
            submission.submission_documents.create!(company_id: @company.id, client_document: document, role: item.role,
              position: position, sha256: item.sha256, file_name_snapshot: item.file.original_filename,
              file_size_snapshot: item.file.size)
            new_documents << document
          end
        end
        period.transition!("submit", actor: @actor, submission: submission)
        new_documents.each do |document|
          PortalActivity.record!(user: @actor, record: document, action: "client_documents#create",
            metadata: PortalActivity.document_metadata(document).merge(payroll_submission_id: submission.id), **@request_context)
        end
        Audit.record!(actor: @actor, period: period, action: "payroll_submissions#create", request_context: @request_context,
          metadata: Audit.submission_metadata(submission))
        PortalNotifications.payroll_submission_sent!(submission)
      end
      files.discard! unless outcome == :created
      if outcome == :created
        submission.submission_documents.each do |link|
          GenerateClientDocumentPreviewJob.perform_later(link.client_document_id) if link.client_document.preview_generation_required?
        rescue StandardError => error
          Rails.logger.warn("Submission preview enqueue failed: #{error.class.name}")
        end
      end
      return replay(submission, request_fingerprint) if outcome == :replayed

      Result.new(submission: submission, outcome: outcome)
    rescue StandardError
      files&.discard!
      raise
    end

    private

    def replay(existing, request_fingerprint)
      raise Conflict, "This retry key was used for a different submission" unless existing.request_fingerprint == request_fingerprint

      Result.new(submission: existing, outcome: :replayed)
    end

    def normalized_answers
      no_changes = ActiveModel::Type::Boolean.new.cast(@params[:no_changes]) || false
      rows = ChangeRows.normalize!(@params[:changes], company_id: @company.id)
      raise FileSet::Invalid, { "changes" => [ "Choose either \"No changes this period\" or list the changes, not both" ] } if no_changes && rows.any?

      link = @params[:changes_link_url].to_s.strip.presence
      if no_changes && link
        raise FileSet::Invalid, { "changes_link_url" => [ "Remove the template link, or untick \"No changes this period\"" ] }
      end
      if link
        uri = URI.parse(link) rescue nil
        raise FileSet::Invalid, { "changes_link_url" => [ "Enter a full https:// link" ] } unless uri.is_a?(URI::HTTPS) && uri.host.present? && link.length <= 2000
      end
      notes = @params[:notes].to_s.strip.presence
      raise FileSet::Invalid, { "notes" => [ "Keep notes under 5,000 characters" ] } if notes && notes.length > 5000

      { no_changes: no_changes, change_rows: rows, changes_link_url: link, notes: notes }
    end

    def keep_document_ids
      Array(@params[:keep_document_ids]).compact_blank.map { |id| Integer(id.to_s, 10) }.uniq.sort
    rescue ArgumentError
      raise FileSet::Invalid, { "keep_document_ids" => [ "Only files from the current revision can be carried forward" ] }
    end

    def incoming_files
      files = []
      files << [ "revel_payroll", @params[:revel_payroll] ] if @params[:revel_payroll].present?
      files << [ "changes_workbook", @params[:changes_workbook] ] if @params[:changes_workbook].present?
      Array(@params[:attachments]).compact_blank.each { |file| files << [ "attachment", file ] }
      files
    end

    def kept_documents(current, keep_ids)
      return [] if keep_ids.empty?

      available = current ? current.submission_documents.to_a.index_by(&:client_document_id) : {}
      missing = keep_ids.reject { |id| available.key?(id) }
      raise FileSet::Invalid, { "keep_document_ids" => [ "Only files from the current revision can be carried forward" ] } if missing.any?

      keep_ids.map { |id| available.fetch(id) }
    end

    def validate_roles!(kept, prepared, no_changes:)
      roles = kept.map(&:role) + prepared.map(&:role)
      errors = {}
      if no_changes && roles.include?("changes_workbook")
        errors["changes_workbook"] = [ "Remove the changes workbook, or untick \"No changes this period\"" ]
      end
      errors["revel_payroll"] = [ "Attach the Revel payroll PDF" ] if roles.count("revel_payroll").zero?
      errors["revel_payroll"] = [ "Send one Revel payroll PDF per revision" ] if roles.count("revel_payroll") > 1
      errors["changes_workbook"] = [ "Send one changes workbook per revision" ] if roles.count("changes_workbook") > 1
      raise FileSet::Invalid, errors if errors.any?
    end

    def content_fingerprint(answers, documents)
      fingerprint(answers: answers, documents: documents.sort)
    end

    def fingerprint(**parts)
      Digest::SHA256.hexdigest(JSON.generate(parts.transform_values { |value| value.is_a?(Hash) ? value.sort.to_h : value }))
    end

    def title_for(item, period, revision)
      case item.role
      when "revel_payroll" then "Revel payroll · #{period.label} · revision #{revision}"
      when "changes_workbook" then "Payroll changes workbook · #{period.label} · revision #{revision}"
      else item.file.original_filename
      end
    end
  end
end
