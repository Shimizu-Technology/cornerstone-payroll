# frozen_string_literal: true

module PayrollSubmissions
  # One projection for both audiences. Client output never includes staff-only
  # drafts or their files, the linked pay run, or any calculated amounts.
  class Serializer
    def initialize(current_user:, catalog:)
      @user = current_user
      @catalog = catalog
      @staff = current_user&.staff_member?
      @documents = ClientPortalThreadSerializer.new(current_user: current_user)
    end

    def summary(entry)
      record = entry.record
      current = record&.current_submission
      payload = {
        ref: entry.ref, id: record&.id, start_date: entry.start_date, end_date: entry.end_date,
        label: PeriodLabel.call(entry.start_date, entry.end_date), pay_date: @catalog.pay_date_for(entry),
        status: record&.status || "waiting_for_files",
        status_label: PayrollSubmissionPeriod::STATUS_LABELS.fetch(record&.status || "waiting_for_files"),
        open_for_files: @catalog.open_for_files?(entry), opens_on: entry.end_date,
        current_revision: current&.revision, last_submitted_at: current&.submitted_at,
        status_changed_at: record&.status_changed_at
      }
      if @staff
        pay_period = @catalog.live_pay_period(entry)
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
        thread_id: record&.client_portal_thread_id,
        file_requests: record ? file_requests(record) : [],
        submissions: [], drafts: [], history: [],
        allowed_actions: allowed_actions(entry)
      )
      return payload unless record

      submissions = record.submissions.includes(:submitted_by, :acknowledged_by, submission_documents: { client_document: %i[employee uploaded_by] }).to_a
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
      if @staff
        actions = []
        actions << "acknowledge" if status == "submitted"
        actions << "start_review" if %w[received changes_requested].include?(status)
        actions << "post_draft" if PayrollSubmissionPeriod::EVENTS["post_draft"][:from].include?(status)
        actions << "save_draft" unless status == "paid"
        actions << "mark_paid" if %w[draft_ready approved].include?(status) && !record&.outstanding_file_requests&.exists?
        actions << "message"
        actions
      else
        actions = []
        actions << "submit" if status != "paid" && @catalog.open_for_files?(entry)
        actions += %w[approve request_changes] if status == "draft_ready"
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
        no_changes: submission.no_changes, notes: submission.notes, changes_link_url: submission.changes_link_url,
        changes: submission.change_rows.map do |row|
          row.merge(
            "label" => ChangeRows::LABELS[row["kind"]],
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
        to_status_label: PayrollSubmissionPeriod::STATUS_LABELS.fetch(event.to_status),
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
