# frozen_string_literal: true

# The same authorized SQL projection backs both list and counters. Pagination
# freezes activity at a signed snapshot and seeks by (activity_at, kind, id),
# so new messages cannot move a row across pages during a traversal.
class ClientInboxQuery
  KINDS = %w[message document employee_change employee_verification payroll_submission payroll_review file_request].freeze
  STATUSES = %w[all unread waiting handled].freeze

  def initialize(user:, params: {})
    @user = User.find(user.id)
    @params = params
    raise ArgumentError, "Invalid kind" if params[:kind].present? && !KINDS.include?(params[:kind])
    raise ArgumentError, "Invalid status" if params[:status].present? && !STATUSES.include?(params[:status])
  end

  def companies
    scope = Company.active.joins(:organization).where(organizations: { status: "active" }).where(organization_id: @user.organization_id, test_workspace_archived_at: nil, test_workspace_sealed_at: nil)
    scope = scope.where("companies.test_workspace_expires_at IS NULL OR companies.test_workspace_expires_at > ?", Time.current)
    # Operating companies (real live clients plus demo companies) and ready
    # sandboxes appear in inbox rows; summary counters stay live-only (NOT demo).
    scope = scope.where("#{Company::OPERATING_SQL} OR (companies.test_workspace_purpose = 'sandbox' AND companies.migration_rehearsal_status = 'ready')")
    scope = scope.where(id: accessible_ids) unless @user.organization_admin?
    scope
  end

  def summary
    scoped_companies = inbox_companies
    verification_ids = verification_company_ids(scoped_companies)
    verification_count = if verification_ids.any?
      ", COUNT(*) FILTER (WHERE kind = 'employee_verification' AND waiting) AS pending_verifications"
    end
    sql = to_sql(Time.current, scoped_companies: scoped_companies, verification_ids: verification_ids, actionable_reviews_only: true)
    row = connection.select_one("SELECT COUNT(*) FILTER (WHERE unread) AS unread_count, COUNT(*) FILTER (WHERE waiting) AS waiting_count, COUNT(*) FILTER (WHERE kind = 'message' AND unread) AS unread_messages, COUNT(*) FILTER (WHERE kind = 'document' AND unread) AS unread_documents, COUNT(*) FILTER (WHERE kind = 'employee_change' AND waiting) AS pending_changes, COUNT(*) FILTER (WHERE kind IN ('payroll_submission', 'payroll_review') AND waiting) AS waiting_payroll, COUNT(*) FILTER (WHERE kind = 'file_request' AND waiting) AS waiting_file_requests#{verification_count} FROM (#{sql}) inbox JOIN companies counted_company ON counted_company.id = inbox.company_id WHERE counted_company.payroll_environment = 'live' AND counted_company.demo = FALSE")
    row.transform_values(&:to_i)
  end

  def page
    per_page = @params[:per_page].to_i.clamp(1, 100)
    per_page = 25 unless @params[:per_page].to_i.positive?
    cursor = decode_cursor
    snapshot = cursor ? Time.iso8601(cursor.fetch("snapshot")) : Time.current
    sql = "SELECT * FROM (#{to_sql(snapshot)}) inbox"
    if cursor
      sql += sanitize(" WHERE (activity_at, kind, id) < (?, ?, ?)", Time.iso8601(cursor.fetch("at")), cursor.fetch("kind"), cursor.fetch("id"))
    end
    rows = connection.select_all("#{sql} ORDER BY activity_at DESC, kind DESC, id DESC LIMIT #{(per_page + 1).to_i}").to_a
    more = rows.size > per_page
    rows = rows.first(per_page)
    last = rows.last
    next_cursor = if more
      verifier.generate({ snapshot: snapshot.iso8601(6), at: last.fetch("activity_at").to_time.iso8601(6), kind: last.fetch("kind"), id: last.fetch("id") }, purpose: cursor_purpose, expires_in: 1.hour)
    end
    requests = PortalFileRequest.where(id: rows.select { |row| row["kind"] == "file_request" }.map { |row| row["id"] }).index_by(&:id)
    review_packages = PayrollReviewPackage.summary.where(id: rows.select { |row| row["kind"] == "payroll_review" }.map { |row| row["id"] }).index_by(&:id)
    { data: rows.map { |row| serialize(row, requests, review_packages) }, meta: { next_cursor: next_cursor, per_page: per_page } }
  rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, ArgumentError => error
    raise ArgumentError, "Invalid inbox cursor" if @params[:cursor].present?

    raise error
  end

  private

  def accessible_ids
    # Unlike the legacy home-company fallback, an expired explicit assignment
    # must never restore access to that same company in the global inbox.
    assignments = @user.company_assignments
    assignments.exists? ? assignments.active_access.select(:company_id) : [ @user.company_id ]
  end

  def inbox_companies
    @params[:company_id].present? ? companies.where(id: @params[:company_id]) : companies
  end

  # Values are quoted through sanitize_sql_array; company subqueries are
  # compiled by ActiveRecord rather than assembled from request strings.
  def to_sql(snapshot, scoped_companies: inbox_companies, verification_ids: nil, actionable_reviews_only: false)
    ids = scoped_companies.select(:id).to_sql
    review_ids = if StaffRolePolicy.allowed?(@user, :manage_client_configuration)
      ids
    else
      scoped_companies.where(id: @user.company_assignments.active_access.where(client_management: true).select(:company_id)).select(:id).to_sql
    end
    review_actionable_filter = if actionable_reviews_only || @params[:status] == "waiting"
      "AND prp.superseded_at IS NULL AND pp.status = 'approved'"
    else
      ""
    end
    sql = sanitize(<<~SQL, @user.id, @user.created_at, @user.id, snapshot, @user.id, @user.created_at, snapshot, snapshot, @user.created_at, snapshot, @user.id, snapshot, @user.created_at, @user.id, snapshot, snapshot)
      SELECT t.id, t.company_id, 'message' AS kind, t.subject AS title,
        COALESCE(MAX(m.created_at), t.created_at) AS activity_at,
        COALESCE((SELECT COALESCE(x.author_name_snapshot, a.name, 'Former portal user') FROM client_portal_messages x LEFT JOIN users a ON a.id = x.author_id WHERE x.client_portal_thread_id = t.id AND x.kind <> 'file_response' AND x.created_at <= #{connection.quote(snapshot)} ORDER BY x.id DESC LIMIT 1), t.created_by_name_snapshot, creator.name, 'Former portal user') AS sender_name,
        COALESCE(BOOL_OR(m.author_audience <> 'staff' AND m.id > GREATEST(t.read_baseline_message_id, COALESCE(r.last_displayed_message_id, 0)) AND m.author_id IS DISTINCT FROM ? AND m.created_at >= ?), FALSE) AS unread,
        ((t.status = 'open' OR COALESCE(MAX(m.created_at), t.created_at) > t.resolved_at) AND COALESCE((SELECT x.author_audience <> 'staff' FROM client_portal_messages x WHERE x.client_portal_thread_id = t.id AND x.kind <> 'file_response' AND x.created_at <= #{connection.quote(snapshot)} ORDER BY x.id DESC LIMIT 1), t.created_by_audience <> 'staff')) AS waiting
      FROM client_portal_threads t
      LEFT JOIN client_portal_messages m ON m.client_portal_thread_id = t.id AND m.kind <> 'file_response' AND m.created_at <= #{connection.quote(snapshot)}
      LEFT JOIN users creator ON creator.id = t.created_by_id
      LEFT JOIN portal_thread_read_receipts r ON r.client_portal_thread_id = t.id AND r.user_id = ?
      WHERE t.company_id IN (#{ids}) AND t.created_at <= ?
      GROUP BY t.id, r.last_displayed_message_id, creator.name
      HAVING COALESCE(BOOL_OR(m.author_audience <> 'staff'), FALSE) OR t.created_by_audience <> 'staff'
      UNION ALL
      SELECT d.id, d.company_id, 'document', d.title, d.created_at, uploader.name,
        (NOT EXISTS (SELECT 1 FROM portal_document_read_receipts r WHERE r.client_document_id = d.id AND r.user_id = ?) AND d.created_at >= ?),
        (d.reviewed_at IS NULL)
      FROM client_documents d LEFT JOIN users uploader ON uploader.id = d.uploaded_by_id
      WHERE d.company_id IN (#{ids}) AND d.shared_by_staff = FALSE AND d.archived_at IS NULL AND d.created_at <= ?
        AND NOT EXISTS (SELECT 1 FROM payroll_submission_documents psd WHERE psd.client_document_id = d.id)
        AND NOT (d.uploaded_for_message AND EXISTS (SELECT 1 FROM portal_message_attachments pma JOIN client_portal_messages pm ON pm.id = pma.client_portal_message_id
          WHERE pma.client_document_id = d.id AND pm.author_id = d.uploaded_by_id))
      UNION ALL
      SELECT e.id, e.company_id, 'employee_change', 'Employee change request', e.created_at, requester.name, FALSE, (e.status = #{EmployeeChangeRequest.statuses.fetch('pending')})
      FROM employee_change_requests e LEFT JOIN users requester ON requester.id = e.requested_by_id WHERE e.company_id IN (#{review_ids}) AND e.created_at <= ?
      UNION ALL
      SELECT p.id, p.company_id, 'payroll_submission',
        'Payroll ' || CASE
          WHEN EXTRACT(YEAR FROM p.start_date) <> EXTRACT(YEAR FROM p.end_date) THEN to_char(p.start_date, 'Mon FMDD, YYYY') || ' – ' || to_char(p.end_date, 'Mon FMDD, YYYY')
          WHEN EXTRACT(MONTH FROM p.start_date) <> EXTRACT(MONTH FROM p.end_date) THEN to_char(p.start_date, 'Mon FMDD') || ' – ' || to_char(p.end_date, 'Mon FMDD, YYYY')
          ELSE to_char(p.start_date, 'Mon FMDD') || '–' || to_char(p.end_date, 'FMDD, YYYY') END,
        latest.created_at, COALESCE(actor.name, latest.actor_name_snapshot, 'Former portal user'),
        (latest.created_at >= ? AND latest.id > COALESCE(r.last_seen_event_id, 0)),
        (p.status IN ('submitted', 'approved', 'changes_requested'))
      FROM payroll_submission_periods p
      JOIN LATERAL (SELECT e.id, e.created_at, e.actor_id, e.actor_name_snapshot FROM payroll_submission_status_events e
        WHERE e.payroll_submission_period_id = p.id AND e.actor_audience = 'client' AND e.created_at <= ?
        ORDER BY e.id DESC LIMIT 1) latest ON TRUE
      LEFT JOIN users actor ON actor.id = latest.actor_id
      LEFT JOIN payroll_submission_period_read_receipts r ON r.payroll_submission_period_id = p.id AND r.user_id = ?
      WHERE p.company_id IN (#{ids}) AND p.created_at <= ?
      UNION ALL
      SELECT f.id, f.company_id, 'file_request', 'File request: ' || f.title,
        CASE WHEN f.responded_at <= #{connection.quote(snapshot)} THEN f.responded_at ELSE f.created_at END,
        CASE WHEN f.responded_at <= #{connection.quote(snapshot)} THEN COALESCE(responder.name, 'Former portal user') ELSE COALESCE(requester.name, f.requested_by_name_snapshot, 'Former portal user') END,
        (f.status = 'responded' AND f.responded_at <= #{connection.quote(snapshot)} AND f.responded_at >= ?
          AND f.last_response_message_id > GREATEST(ft.read_baseline_message_id, COALESCE(fr.last_displayed_message_id, 0))),
        (f.status = 'responded')
      FROM portal_file_requests f
      JOIN client_portal_threads ft ON ft.id = f.client_portal_thread_id
      LEFT JOIN users responder ON responder.id = f.responded_by_id
      LEFT JOIN users requester ON requester.id = f.requested_by_id
      LEFT JOIN portal_thread_read_receipts fr ON fr.client_portal_thread_id = ft.id AND fr.user_id = ?
      WHERE f.company_id IN (#{ids}) AND f.created_at <= ?
      UNION ALL
      SELECT prp.id, prp.company_id, 'payroll_review',
        CASE
          WHEN prp.approval_method = 'cornerstone_override' THEN 'Cornerstone approved for client · '
          WHEN prp.approved_at IS NOT NULL THEN 'Payroll approved · '
          ELSE 'Payroll changes requested · '
        END ||
        CASE
          WHEN EXTRACT(YEAR FROM pp.start_date) <> EXTRACT(YEAR FROM pp.end_date) THEN to_char(pp.start_date, 'Mon FMDD, YYYY') || ' – ' || to_char(pp.end_date, 'Mon FMDD, YYYY')
          WHEN EXTRACT(MONTH FROM pp.start_date) <> EXTRACT(MONTH FROM pp.end_date) THEN to_char(pp.start_date, 'Mon FMDD') || ' – ' || to_char(pp.end_date, 'Mon FMDD, YYYY')
          ELSE to_char(pp.start_date, 'Mon FMDD') || '–' || to_char(pp.end_date, 'FMDD, YYYY') END,
        COALESCE(prp.approved_at, prp.changes_requested_at),
        COALESCE(decider.name, 'Former portal user'),
        FALSE,
        (prp.superseded_at IS NULL AND pp.status = 'approved')
      FROM payroll_review_packages prp
      JOIN pay_periods pp ON pp.id = prp.pay_period_id
      LEFT JOIN users decider ON decider.id = COALESCE(prp.approved_by_id, prp.changes_requested_by_id)
      WHERE prp.company_id IN (#{ids})
        AND prp.published_at IS NOT NULL
        #{review_actionable_filter}
        AND pp.correction_status IS DISTINCT FROM 'voided'
        AND (prp.approved_at IS NOT NULL OR prp.changes_requested_at IS NOT NULL)
        AND COALESCE(prp.approved_at, prp.changes_requested_at) <= ?
    SQL
    if @params[:kind].blank? || @params[:kind] == "employee_verification"
      sql += verification_sql(verification_ids || verification_company_ids(scoped_companies), snapshot)
    end
    conditions = []
    conditions << sanitize("kind = ?", @params[:kind]) if @params[:kind].present?
    case @params[:status]
    when "unread" then conditions << "unread"
    when "waiting" then conditions << "waiting"
    when "handled" then conditions << "NOT waiting"
    end
    "SELECT inbox.*, c.name AS company_name, (c.payroll_environment = 'migration_rehearsal' AND c.test_workspace_purpose IS DISTINCT FROM 'demo') AS practice_copy, (c.demo = TRUE OR (c.payroll_environment = 'migration_rehearsal' AND c.test_workspace_purpose = 'demo')) AS demo FROM (#{sql}) inbox JOIN companies c ON c.id = inbox.company_id#{conditions.any? ? " WHERE #{conditions.join(' AND ')}" : ''}"
  end

  def verification_company_ids(scoped_companies)
    return [] unless StaffEmployeeLifecycle.unlocked?
    return [] unless StaffRolePolicy.allowed?(@user, :payroll_operations)

    StaffEmployeeLifecycle.companies(scoped_companies).pluck(:id)
  end

  def verification_sql(company_ids, snapshot)
    return "" if company_ids.empty?

    sanitize(<<~SQL, company_ids, snapshot)
      UNION ALL
      SELECT v.id, v.company_id, 'employee_verification', 'Employee update to verify', v.updated_at,
        actor.name, FALSE, (v.status = 'pending_verification')
      FROM employee_verification_items v
      LEFT JOIN users actor ON actor.id = v.source_actor_id
      WHERE v.company_id IN (?) AND v.updated_at <= ? AND v.status <> 'superseded'
    SQL
  end

  def serialize(row, requests = {}, review_packages = {})
    payload = { id: row["id"].to_i, key: "#{row['kind']}:#{row['id']}", company_id: row["company_id"].to_i,
      company_name: row["company_name"], practice_copy: row["practice_copy"], demo: row["demo"], sender_name: row["sender_name"], kind: row["kind"], title: row["title"],
      activity_at: row["activity_at"], unread: row["unread"], waiting: row["waiting"] }
    if (request = requests[row["id"].to_i]) && row["kind"] == "file_request"
      payload.merge!(thread_id: request.client_portal_thread_id, state: request.status, state_label: request.status_label)
    elsif (package = review_packages[row["id"].to_i]) && row["kind"] == "payroll_review"
      state = package.approved_at.present? ? "approved" : "changes_requested"
      state_label = if row["waiting"]
        state == "approved" ? "Approved — ready to commit" : "Changes requested"
      else
        state == "approved" ? "Approved · Handled" : "Changes requested · Handled"
      end
      payload.merge!(pay_period_id: package.pay_period_id, state: state, state_label: state_label)
    end
    payload
  end

  def decode_cursor
    verifier.verify(@params[:cursor], purpose: cursor_purpose) if @params[:cursor].present?
  end

  def cursor_purpose
    [ "client-inbox", @user.id, @params[:company_id], @params[:kind], @params[:status] ].join(":")
  end

  def verifier
    Rails.application.message_verifier("client-inbox")
  end

  def connection
    ApplicationRecord.connection
  end

  def sanitize(sql, *values)
    ApplicationRecord.sanitize_sql_array([ sql, *values ])
  end
end
