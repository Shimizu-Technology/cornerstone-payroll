# frozen_string_literal: true

# Who has an employee app account and what they agreed to, one row per active
# employee, for the staff app and the client portal. It only reads existing
# sources: the employee's links (EmployeeAppRollout's display rule), the
# Employee App Terms version recorded on a link's sign-up, claim or
# reactivation audit row, each login's latest recorded app open (the audited
# context read), and DeliveryConsents::Answers. No IP addresses, devices,
# SSNs or birth dates.
#
# Two separate measures:
# - Signed up: a link is active and its login is turned on, now. A sign-up
#   reset, a rehire's new invite or a turned-off login is not signed up.
# - Opened the app: a recorded app open by any of the employee's logins here,
#   recorded since APP_OPENS_RECORDED_SINCE.
class EmployeeAppStatusReport
  FILTERS = %w[not_signed_up signed_up_no_opens invite_expired terms_not_accepted no_paperless_answer kept_paper].freeze
  TERMS_ACTIONS = %w[employee_links#sign_up_started employee_links#claimed employee_links#reactivated].freeze
  APP_OPEN_ACTION = "employee_portal/context#show"
  # Employee app requests have been audited since #564 (employee link lifecycle).
  APP_OPENS_RECORDED_SINCE = Date.new(2026, 11, 25)
  # 1099 contractors get no W-2GU, so they have no W-2GU answer to give.
  NOT_APPLICABLE = "not_applicable"
  ANSWER_LABELS = {
    NOT_APPLICABLE => "Not applicable (1099)",
    DeliveryConsents::Answers::PAPERLESS => "Paperless",
    DeliveryConsents::Answers::KEEP_PAPER => "Keep paper",
    DeliveryConsents::Answers::NOT_ANSWERED => "Not answered"
  }.freeze
  HEADERS = [
    "Employee", "Department", "Role", "App account", "Invite sent", "Invite expires", "Signed up", "Last recorded app open",
    "Terms version", "Terms accepted", "Pay stubs", "Pay stubs answered", "W-2GU", "W-2GU answered"
  ].freeze

  def initialize(company, now: Time.current)
    @company = company
    @now = now
    @rollout = EmployeeAppRollout.new(company, now: now)
  end

  # The page: counts cover every active employee; the filters only narrow the rows.
  def call(filter: nil, department_id: nil, role: nil, query: nil)
    all = rows_for(active_employees.to_a)
    shown = scoped(department_id: department_id, role: role, query: query).pluck(:id).to_set
    {
      enabled: @rollout.enabled,
      delivery_consent_enabled: delivery_consent_enabled?,
      current_terms_version: current_terms&.version,
      opens_recorded_since: APP_OPENS_RECORDED_SINCE.iso8601,
      summary: summary(all),
      departments: all.filter_map { |row| row[:department] }.uniq { |department| department[:id] }.sort_by { |department| department[:name].downcase },
      roles: all.filter_map { |row| row[:role] }.uniq.sort_by(&:downcase),
      employees: all.select { |row| shown.include?(row[:id]) && matches_filter?(row, filter) }
    }
  end

  # The export: the same rows as the page for these params, computed only for
  # the employees the department, role and name filters leave.
  def export_rows(filter: nil, department_id: nil, role: nil, query: nil)
    rows_for(scoped(department_id: department_id, role: role, query: query).to_a).select { |row| matches_filter?(row, filter) }
  end

  # The same facts for one employee, active or not (the employee profile panel).
  def row(employee)
    rows_for([ employee ]).first
  end

  def sheet(rows)
    {
      name: "Employee app status",
      rows: [ HEADERS ] + rows.map { |row| export_row(row) },
      column_widths: [ 28, 18, 18, 16, 14, 14, 14, 18, 18, 14, 14, 14, 14, 14 ],
      styles: { header: { b: true } },
      row_style_rules: [ { rows: [ 0 ], style: :header } ]
    }
  end

  def filename(extension)
    "#{@company.name.parameterize}-employee-app-status-#{@now.in_time_zone(PayrollBusinessClock::TIME_ZONE).to_date.iso8601}.#{extension}"
  end

  private

  def active_employees
    @company.employees.active.includes(:department).order(:last_name, :first_name, :id)
  end

  def scoped(department_id:, role:, query:)
    scope = active_employees
    scope = scope.where(department_id: department_id) if department_id.present?
    scope = scope.where(job_title: role) if role.present?
    if query.present?
      pattern = "%#{Employee.sanitize_sql_like(query.to_s.squish.downcase)}%"
      # The shown name (first, middle, last, business) or first and last together.
      scope = scope.where(
        "LOWER(CONCAT_WS(' ', employees.first_name, employees.middle_name, employees.last_name, employees.business_name)) LIKE :pattern " \
        "OR LOWER(CONCAT_WS(' ', employees.first_name, employees.last_name)) LIKE :pattern", pattern: pattern
      )
    end
    scope
  end

  def rows_for(employees)
    ids = employees.map(&:id)
    links = EmployeeAccountLink.where(company_id: @company.id, employee_id: ids).order(:id).to_a
    links_by_employee = links.group_by(&:employee_id)
    users = User.where(id: links.filter_map(&:user_id)).index_by(&:id)
    reinvited = @rollout.reinvited_link_ids(links)
    terms = latest_terms(ids)
    opens = latest_opens(users.keys)
    answers = DeliveryConsents::Answers.by_employee(@company.id, ids)

    employees.map do |employee|
      employee_links = links_by_employee.fetch(employee.id, [])
      access = employee_links.last
      signed_up_link = employee_links.reverse.find { |link| link.active? && users[link.user_id]&.active? }
      opened_at = employee_links.filter_map { |link| opens[link.user_id] }.max
      accepted = terms[employee.id]
      status = @rollout.display_status(access, user: users[access&.user_id], reinvited: reinvited.include?(access&.id))
      {
        id: employee.id,
        name: employee.display_name,
        department: employee.department && { id: employee.department.id, name: employee.department.name },
        role: employee.job_title.presence,
        account: {
          status: status,
          label: EmployeeAppRollout::DISPLAY_LABELS.fetch(status),
          signed_up: signed_up_link.present?,
          invite_sent_at: access && (access.last_invited_at || access.created_at).iso8601,
          invite_expires_at: (access.invite_expires_at&.iso8601 if access&.invited?),
          invite_expired: access&.invited? && access.invite_expires_at.present? && access.invite_expires_at <= @now || false,
          signed_up_at: signed_up_link&.activated_at&.iso8601,
          last_opened_at: opened_at&.iso8601,
          locked_until: (access.activation_locked_until&.iso8601 if status == :locked)
        },
        terms: {
          version: accepted&.terms_version,
          accepted_at: accepted&.created_at&.iso8601,
          current: accepted.present? && accepted.terms_version == current_terms&.version
        },
        pay_statements: answer_payload(answers.dig(employee.id, "pay_statements")),
        w2gu: employee.contractor? ? { answer: NOT_APPLICABLE, answered_at: nil } : answer_payload(answers.dig(employee.id, "w2gu"))
      }
    end
  end

  def answer_payload(answer)
    { answer: answer[:answer], answered_at: answer[:answered_at]&.iso8601 }
  end

  # The terms version each employee agreed to most recently, across their links.
  def latest_terms(employee_ids)
    return {} if employee_ids.empty?

    AuditLog.find_by_sql([ <<~SQL.squish, { company_id: @company.id, record_type: EmployeeLinks::AUDIT_RECORD_TYPE, actions: TERMS_ACTIONS, ids: employee_ids } ])
      SELECT DISTINCT ON (links.employee_id) links.employee_id AS employee_id,
        audit_logs.metadata ->> 'terms_version' AS terms_version, audit_logs.created_at AS created_at
      FROM audit_logs
      JOIN employee_account_links links ON links.id = audit_logs.record_id AND links.company_id = audit_logs.company_id
      WHERE audit_logs.company_id = :company_id AND audit_logs.record_type = :record_type
        AND audit_logs.action IN (:actions) AND jsonb_exists(audit_logs.metadata, 'terms_version')
        AND links.employee_id IN (:ids)
      ORDER BY links.employee_id, audit_logs.created_at DESC, audit_logs.id DESC
    SQL
      .index_by(&:employee_id)
  end

  # Each login's latest recorded app open: one step per login down
  # idx_audit_logs_employee_app_opens (the action is inlined so the partial
  # index matches under prepared statements).
  def latest_opens(user_ids)
    return {} if user_ids.empty?

    action = AuditLog.connection.quote(APP_OPEN_ACTION)
    AuditLog.find_by_sql([ <<~SQL.squish, { company_id: @company.id, ids: user_ids } ])
      SELECT logins.user_id AS user_id, latest.created_at AS created_at
      FROM unnest(ARRAY[:ids]::bigint[]) AS logins(user_id)
      CROSS JOIN LATERAL (
        SELECT audit_logs.created_at FROM audit_logs
        WHERE audit_logs.company_id = :company_id AND audit_logs.user_id = logins.user_id AND audit_logs.action = #{action}
        ORDER BY audit_logs.created_at DESC LIMIT 1
      ) latest
    SQL
      .to_h { |open| [ open.user_id, open.created_at ] }
  end

  def summary(rows)
    {
      total: rows.size,
      signed_up: rows.count { |row| row.dig(:account, :signed_up) },
      opened: rows.count { |row| row.dig(:account, :last_opened_at) },
      **FILTERS.index_with { |filter| rows.count { |row| matches_filter?(row, filter) } }.symbolize_keys
    }
  end

  def matches_filter?(row, filter)
    return true unless FILTERS.include?(filter)

    answers = [ row.dig(:pay_statements, :answer), row.dig(:w2gu, :answer) ]
    case filter
    when "not_signed_up" then !row.dig(:account, :signed_up)
    when "signed_up_no_opens" then row.dig(:account, :signed_up) && row.dig(:account, :last_opened_at).nil?
    when "invite_expired" then row.dig(:account, :invite_expired)
    when "terms_not_accepted" then !row.dig(:terms, :current)
    when "no_paperless_answer" then answers.include?(DeliveryConsents::Answers::NOT_ANSWERED)
    when "kept_paper" then answers.include?(DeliveryConsents::Answers::KEEP_PAPER)
    end
  end

  def export_row(row)
    account = row[:account]
    [
      row[:name], row.dig(:department, :name), row[:role], account[:label],
      day(account[:invite_sent_at]), day(account[:invite_expires_at]), day(account[:signed_up_at]),
      day(account[:last_opened_at]) || "No recorded opens",
      row.dig(:terms, :version) || "Not accepted", day(row.dig(:terms, :accepted_at)),
      ANSWER_LABELS.fetch(row.dig(:pay_statements, :answer)), day(row.dig(:pay_statements, :answered_at)),
      ANSWER_LABELS.fetch(row.dig(:w2gu, :answer)), day(row.dig(:w2gu, :answered_at))
    ]
  end

  # Guam calendar day, the way the app shows dates.
  def day(timestamp)
    timestamp && Time.iso8601(timestamp).in_time_zone(PayrollBusinessClock::TIME_ZONE).to_date.iso8601
  end

  def current_terms
    return @current_terms if defined?(@current_terms)

    @current_terms = EmployeeTermsVersion.current
  end

  def delivery_consent_enabled?
    CompanyFeatures.for(@company).employee_portal_feature?(:delivery_consent)
  end
end
