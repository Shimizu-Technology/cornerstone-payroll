# frozen_string_literal: true

module PayrollSubmissions
  # One projection for both audiences. Client output never includes staff-only
  # drafts or their files. Published review links expose no calculated amounts.
  class Serializer
    def initialize(current_user:, catalog:)
      @user = current_user
      @catalog = catalog
      @staff = current_user&.staff_member?
      @documents = ClientPortalThreadSerializer.new(current_user: current_user)
    end

    def summaries(entries)
      @catalog.preload_live_pay_periods(entries)
      ids = entries.filter_map { |entry| @catalog.live_pay_period(entry)&.id }
      @published_reviews = ids.index_with { nil }
      PayrollReviewPackage.summary.current.where(pay_period_id: ids).where.not(published_at: nil).find_each do |package|
        @published_reviews[package.pay_period_id] = package
      end
      ActiveRecord::Associations::Preloader.new(records: entries.filter_map(&:record),
        associations: [ :submissions, :status_events, :read_receipts, :file_requests ]).call
      entries.map { |entry| summary(entry) }
    end

    def summary(entry)
      record = entry.record
      current = record&.current_submission
      payload = {
        ref: entry.ref, id: record&.id, start_date: entry.start_date, end_date: entry.end_date,
        label: PeriodLabel.call(entry.start_date, entry.end_date), pay_date: @catalog.pay_date_for(entry),
        status: record&.status || "waiting_for_files",
        status_label: !@catalog.company.payroll_intake_source_enabled?("mosa_revel") && (!record || record.status == "waiting_for_files") ? "Messages and drafts" : PayrollSubmissionPeriod::STATUS_LABELS.fetch(record&.status || "waiting_for_files"),
        accepts_files: @catalog.company.payroll_intake_source_enabled?("mosa_revel"),
        open_for_files: @catalog.open_for_files?(entry), opens_on: entry.end_date,
        current_revision: current&.revision, last_submitted_at: current&.submitted_at,
        status_changed_at: record&.status_changed_at
      }
      pay_period = @catalog.live_pay_period(entry)
      if pay_period && record&.status.in?(%w[draft_ready approved changes_requested paid]) && !pay_period.client_finished?
        payload[:status] = "in_review"
        payload[:status_label] = @catalog.company.client_payroll_approval_required? ? "Awaiting payroll preview" : "Payroll in progress"
      end
      if pay_period
        @published_reviews ||= {}
        published = if @published_reviews.key?(pay_period.id)
          @published_reviews[pay_period.id]
        else
          @published_reviews[pay_period.id] = pay_period.payroll_review_packages.summary.current.where.not(published_at: nil).first
        end
        published = nil unless @catalog.company.client_payroll_approval_required?
        visible = @staff || pay_period.client_finished? || (pay_period.approved? && published)
        payload[:review_pay_period_id] = pay_period.id if visible
        if pay_period.client_finished?
          payload[:status] = "paid"
          payload[:status_label] = "Paid"
        elsif pay_period.approved? && published
          payload[:status], payload[:status_label] = if published.changes_requested_at
            [ "changes_requested", "Changes requested on payroll preview" ]
          elsif published.approved?
            [ "approved", "Client approved payroll preview" ]
          else
            [ "draft_ready", "Payroll preview ready for review" ]
          end
        end
      end
      unless @staff
        payload[:client_payroll_status] = case payload[:status]
        when "paid" then pay_period&.client_finished? ? "committed" : "preparing"
        when "draft_ready" then payload[:review_pay_period_id] ? "pending" : "preparing"
        when "approved", "changes_requested" then payload[:review_pay_period_id] ? payload[:status] : "preparing"
        else "preparing"
        end
      end
      if payload[:status] == "paid" && record && record.file_requests.any?(&:outstanding?)
        payload[:status] = "in_review"
        payload[:status_label] = "Requested files outstanding"
      end
      if @staff
        link_warning = @catalog.retired_link_warning(entry)
        payload[:pay_period_link_error] = link_warning if link_warning
        ambiguous_ids = @catalog.ambiguous_pay_period_ids(entry)
        if ambiguous_ids.any?
          payload[:pay_period_link_error] = "Payroll files match multiple pay runs (#{ambiguous_ids.join(', ')}). Import the files into the correct pay run, or withdraw the open file requests, before committing."
        end
        payload[:pay_period_id] = pay_period&.id
        payload[:source] = entry.source
        payload[:unread] = record ? unread?(record) : false
        payload[:latest_client_event_id] = record ? latest_client_event(record)&.id || 0 : 0
      end
      payload
    end

    def detail(entry)
      record = entry.record
      payload = summary(entry).merge(
        schedule_note: schedule_note,
        standing_changes: StandingChanges.new(company: @catalog.company, before_pay_date: @catalog.pay_date_for(entry), rates_on: entry.end_date).rows.reject { |row| !@staff && row[:availability_error].present? },
        thread_id: record&.client_portal_thread_id,
        file_requests: record ? file_requests(record) : [],
        submissions: [], drafts: [], history: [],
        allowed_actions: allowed_actions(entry)
      )
      return payload unless record

      submissions = record.submissions.includes(:submitted_by, :acknowledged_by, submission_documents: { client_document: %i[employee uploaded_by] }).to_a
      @standing_fields = if @staff
        PayrollStandingChange.where(company_id: record.company_id, id: submissions.flat_map { |s| s.change_rows.pluck("standing_change_id") }.compact.uniq)
          .includes(:employee, :employee_wage_rate).index_by(&:id)
      else
        {}
      end
      employee_names = Employee.where(company_id: record.company_id, id: submissions.flat_map { |s| s.change_rows.flat_map { |row| [ row["employee_id"], *Array(row["employee_ids"]) ] } }.compact.uniq)
        .to_h { |employee| [ employee.id, employee.full_name ] }
      payload[:submissions] = submissions.each_with_index.map { |submission, index| submission(submission, current: index.zero?, employee_names: employee_names) }
      drafts = record.drafts.includes(paycheck_document: %i[employee uploaded_by], direct_deposit_document: %i[employee uploaded_by]).to_a
      drafts = drafts.select(&:posted?) unless @staff
      current_draft = drafts.find(&:posted?)
      payload[:drafts] = drafts.map { |draft| draft(draft, current: draft == current_draft) }
      payload[:history] = record.status_events.map { |event| history(event) }
      payload
    end

    def allowed_actions(entry)
      record = entry.record
      status = record&.status || "waiting_for_files"
      run = @catalog.live_pay_period(entry)
      finished = run ? run.client_finished? : status == "paid"
      return [ "message" ] if finished

      if @staff
        actions = []
        actions << "acknowledge" if status == "submitted"
        actions << "start_review" if %w[received changes_requested].include?(status)
        actions << "message"
        actions
      else
        actions = []
        actions << "submit" if @catalog.company.payroll_intake_source_enabled?("mosa_revel") && !finished && @catalog.open_for_files?(entry)
        actions << "message"
        actions
      end
    end

    private

    # Requests for this period, newest first. Both sides see their state.
    def file_requests(record)
      record.file_requests.includes(:employee, :requested_by, :responded_by, :resolved_by, :payroll_submission_period)
        .order(created_at: :desc, id: :desc).map { |request| @documents.file_request(request) }
    end

    def submission(submission, current:, employee_names:)
      {
        id: submission.id, revision: submission.revision, current: current, superseded: !current,
        submitted_at: submission.submitted_at, submitted_by_name: submission.submitted_by&.name || submission.submitted_by_name_snapshot,
        acknowledged_at: submission.acknowledged_at, acknowledged_by_name: submission.acknowledged_by&.name,
        imported_at: submission.submission_imports.maximum(:applied_at),
        imports: (@staff ? submission.submission_imports.includes(:payroll_import, :staff_workbook_document, :staff_workbook_attached_by).map { |link| { id: link.payroll_import_id, pay_period_id: link.payroll_import.pay_period_id, status: link.payroll_import.status, source_route: link.source_route, staff_workbook: link.staff_workbook_evidence } } : nil),
        workbook_choice: submission.workbook_choice, no_changes: submission.no_changes, notes: submission.notes, changes_link_url: submission.changes_link_url,
        changes: submission.change_rows.map do |row|
          row.except("availability_error").merge(
            "availability_error" => (@standing_fields[row["standing_change_id"]]&.availability_error(rates_on: submission.period.end_date) if @staff),
            "label" => row["label"].presence || ChangeRows::LABELS[row["kind"]],
            "employee_name" => row["employee_id"] && employee_names[row["employee_id"]],
            "employee_names" => row["employee_ids"] && row["employee_ids"].map { |id| employee_names[id] }
          ).compact
        end,
        documents: submission.submission_documents.map do |link|
          { role: link.role, sha256: (link.sha256 if @staff), file_name: link.file_name_snapshot, file_size: link.file_size_snapshot,
            document: @documents.document(link.client_document) }.compact
        end
      }
    end

    def draft(draft, current:)
      payload = {
        id: draft.id, revision: draft.revision, current: current, superseded: draft.posted? && !current,
        posted: draft.posted?, posted_at: draft.posted_at, posted_by_name: draft.posted_by&.name, note: draft.note,
        paycheck_document: @documents.document(draft.paycheck_document),
        direct_deposit_document: @documents.document(draft.direct_deposit_document)
      }
      payload[:created_by_name] = draft.created_by&.name if @staff
      payload
    end

    def history(event)
      {
        id: event.id, event: event.event, from_status: event.from_status, to_status: event.to_status,
        to_status_label: event.to_status == "waiting_for_files" && !@catalog.company.payroll_intake_source_enabled?("mosa_revel") ? "Messages and drafts" : PayrollSubmissionPeriod::STATUS_LABELS.fetch(event.to_status),
        actor_name: event.actor&.name || event.actor_name_snapshot || "Former portal user", actor_audience: event.actor_audience,
        note: event.note, submission_id: event.payroll_submission_id, draft_id: event.payroll_submission_draft_id,
        created_at: event.created_at
      }
    end

    def schedule_note
      if @catalog.derives_from_schedule?
        "Periods follow the company pay schedule."
      else
        "Periods are the pay periods Cornerstone has set up."
      end
    end

    def latest_client_event(record)
      record.status_events.select { |event| event.actor_audience == "client" }.max_by(&:id)
    end

    def unread?(record)
      latest = latest_client_event(record)
      return false unless latest && latest.created_at >= @user.created_at

      seen = record.read_receipts.find { |receipt| receipt.user_id == @user.id }&.last_seen_event_id || 0
      latest.id > seen
    end
  end
end
