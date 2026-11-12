# frozen_string_literal: true

# The same authorized SQL projection backs both list and counters. Pagination
# freezes activity at a signed snapshot and seeks by (activity_at, kind, id),
# so new messages cannot move a row across pages during a traversal.
class ClientInboxQuery
  KINDS = %w[message document employee_change].freeze
  STATUSES = %w[all unread waiting handled].freeze

  def initialize(user:, params: {})
    @user = User.find(user.id)
    @params = params
    raise ArgumentError, "Invalid kind" if params[:kind].present? && !KINDS.include?(params[:kind])
    raise ArgumentError, "Invalid status" if params[:status].present? && !STATUSES.include?(params[:status])
  end

  def companies
    scope = Company.active.live_payroll.joins(:organization).where(organizations: { status: "active" }).where(organization_id: @user.organization_id, test_workspace_archived_at: nil)
    scope = scope.where(id: accessible_ids) unless @user.organization_admin?
    scope
  end

  def summary
    row = connection.select_one("SELECT COUNT(*) FILTER (WHERE unread) AS unread_count, COUNT(*) FILTER (WHERE waiting) AS waiting_count, COUNT(*) FILTER (WHERE kind = 'message' AND unread) AS unread_messages, COUNT(*) FILTER (WHERE kind = 'document' AND unread) AS unread_documents, COUNT(*) FILTER (WHERE kind = 'employee_change' AND waiting) AS pending_changes FROM (#{to_sql(Time.current)}) inbox")
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
    { data: rows.map { |row| serialize(row) }, meta: { next_cursor: next_cursor, per_page: per_page } }
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

  # Values are quoted through sanitize_sql_array; company subqueries are
  # compiled by ActiveRecord rather than assembled from request strings.
  def to_sql(snapshot)
    scoped_companies = companies
    scoped_companies = scoped_companies.where(id: @params[:company_id]) if @params[:company_id].present?
    ids = scoped_companies.select(:id).to_sql
    review_ids = if StaffRolePolicy.allowed?(@user, :manage_client_configuration)
      ids
    else
      scoped_companies.where(id: @user.company_assignments.active_access.where(client_management: true).select(:company_id)).select(:id).to_sql
    end
    sql = sanitize(<<~SQL, @user.id, @user.created_at, @user.id, snapshot, snapshot, @user.id, @user.created_at, snapshot, snapshot)
      SELECT t.id, t.company_id, 'message' AS kind, t.subject AS title,
        MAX(m.created_at) AS activity_at,
        (SELECT a.name FROM client_portal_messages x LEFT JOIN users a ON a.id = x.author_id WHERE x.client_portal_thread_id = t.id AND x.created_at <= #{connection.quote(snapshot)} ORDER BY x.id DESC LIMIT 1) AS sender_name,
        BOOL_OR(author.role = #{User.roles.fetch('client')} AND m.id > GREATEST(t.read_baseline_message_id, COALESCE(r.last_displayed_message_id, 0)) AND m.author_id IS DISTINCT FROM ? AND m.created_at >= ?) AS unread,
        ((t.status = 'open' OR MAX(m.created_at) > t.resolved_at) AND (SELECT a.role = #{User.roles.fetch('client')} FROM client_portal_messages x LEFT JOIN users a ON a.id = x.author_id WHERE x.client_portal_thread_id = t.id AND x.created_at <= #{connection.quote(snapshot)} ORDER BY x.id DESC LIMIT 1)) AS waiting
      FROM client_portal_threads t
      JOIN client_portal_messages m ON m.client_portal_thread_id = t.id
      LEFT JOIN users author ON author.id = m.author_id
      LEFT JOIN portal_thread_read_receipts r ON r.client_portal_thread_id = t.id AND r.user_id = ?
      WHERE t.company_id IN (#{ids}) AND t.created_at <= ? AND m.created_at <= ?
      GROUP BY t.id, r.last_displayed_message_id
      HAVING BOOL_OR(author.role = #{User.roles.fetch('client')})
      UNION ALL
      SELECT d.id, d.company_id, 'document', d.title, d.created_at, uploader.name,
        (NOT EXISTS (SELECT 1 FROM portal_document_read_receipts r WHERE r.client_document_id = d.id AND r.user_id = ?) AND d.created_at >= ?),
        (d.reviewed_at IS NULL)
      FROM client_documents d LEFT JOIN users uploader ON uploader.id = d.uploaded_by_id
      WHERE d.company_id IN (#{ids}) AND d.shared_by_staff = FALSE AND d.archived_at IS NULL AND d.created_at <= ?
      UNION ALL
      SELECT e.id, e.company_id, 'employee_change', 'Employee change request', e.created_at, requester.name, FALSE, (e.status = #{EmployeeChangeRequest.statuses.fetch('pending')})
      FROM employee_change_requests e LEFT JOIN users requester ON requester.id = e.requested_by_id WHERE e.company_id IN (#{review_ids}) AND e.created_at <= ?
    SQL
    conditions = []
    conditions << sanitize("kind = ?", @params[:kind]) if @params[:kind].present?
    case @params[:status]
    when "unread" then conditions << "unread"
    when "waiting" then conditions << "waiting"
    when "handled" then conditions << "NOT waiting"
    end
    "SELECT inbox.*, c.name AS company_name FROM (#{sql}) inbox JOIN companies c ON c.id = inbox.company_id#{conditions.any? ? " WHERE #{conditions.join(' AND ')}" : ''}"
  end

  def serialize(row)
    { id: row["id"].to_i, key: "#{row['kind']}:#{row['id']}", company_id: row["company_id"].to_i,
      company_name: row["company_name"], sender_name: row["sender_name"], kind: row["kind"], title: row["title"],
      activity_at: row["activity_at"], unread: row["unread"], waiting: row["waiting"] }
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
