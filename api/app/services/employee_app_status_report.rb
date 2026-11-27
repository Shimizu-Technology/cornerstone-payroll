# frozen_string_literal: true

# Who has an employee app account and what they agreed to, one row per active
# employee, for the staff app and the client portal. It only reads existing
# sources: the latest access from EmployeeAppRollout, the Employee App Terms
# version recorded on the link's sign-up, claim or reactivation audit row, the
# employee's last app open (the audited context read), and
# DeliveryConsents::Answers. No IP addresses, devices, SSNs or birth dates.
class EmployeeAppStatusReport
  FILTERS = %w[never_signed_in invite_expired terms_not_accepted no_paperless_answer kept_paper].freeze
  TERMS_ACTIONS = %w[employee_links#sign_up_started employee_links#claimed employee_links#reactivated].freeze
  APP_OPEN_ACTION = "employee_portal/context#show"
  ACCOUNT_LABELS = {
    not_invited: "Not invited", invited: "Invited", invite_expired: "Invite expired", locked: "Locked",
    active: "Signed up", deactivated: "Deactivated", former: "Former", revoked: "Revoked"
  }.freeze
  ANSWER_LABELS = {
    DeliveryConsents::Answers::PAPERLESS => "Paperless",
    DeliveryConsents::Answers::KEEP_PAPER => "Keep paper",
    DeliveryConsents::Answers::NOT_ANSWERED => "Not answered"
  }.freeze

  def initialize(company, now: Time.current)
    @company = company
    @now = now
    @rollout = EmployeeAppRollout.new(company, now: now)
  end

  # Rows and counts. Counts always cover every active employee; the filters
  # only narrow the rows.
  def call(filter: nil, department_id: nil, role: nil, query: nil)
    all = rows_for(@company.employees.active.includes(:department).order(:last_name, :first_name, :id).to_a)
    {
      enabled: @rollout.enabled,
      delivery_consent_enabled: delivery_consent_enabled?,
      current_terms_version: current_terms&.version,
      summary: summary(all),
      departments: all.filter_map { |row| row[:department] }.uniq { |department| department[:id] }.sort_by { |department| department[:name].downcase },
      roles: all.filter_map { |row| row[:role] }.uniq.sort_by(&:downcase),
      employees: narrow(all, filter: filter, department_id: department_id, role: role, query: query)
    }
  end

  # The same facts for one employee, active or not (the employee profile panel).
  def row(employee)
    rows_for([ employee ]).first
  end

  def sheet(rows)
    {
      name: "Employee app status",
      rows: [ HEADERS ] + rows.map { |row| export_row(row) },
      column_widths: [ 28, 18, 18, 16, 14, 14, 14, 16, 18, 14, 14, 14, 14, 14 ],
      styles: { header: { b: true } },
      row_style_rules: [ { rows: [ 0 ], style: :header } ]
    }
  end

  def filename(extension)
    "#{@company.name.parameterize}-employee-app-status-#{@now.in_time_zone(PayrollBusinessClock::TIME_ZONE).to_date.iso8601}.#{extension}"
  end

  HEADERS = [
    "Employee", "Department", "Role", "App account", "Invite sent", "Invite expires", "Signed up", "Last opened app",
    "Terms version", "Terms accepted", "Pay stubs", "Pay stubs answered", "W-2GU", "W-2GU answered"
  ].freeze

  private

  def rows_for(employees)
    ids = employees.map(&:id)
    accesses = @rollout.latest_accesses(ids)
    users = User.where(id: accesses.values.filter_map(&:user_id)).index_by(&:id)
    terms = terms_by_employee(ids)
    opened = last_opened(users.keys)
    answers = DeliveryConsents::Answers.by_employee(@company.id, ids)

    employees.map do |employee|
      access = accesses[employee.id]
      user = users[access&.user_id]
      accepted = terms[employee.id]
      {
        id: employee.id,
        name: employee.display_name,
        department: employee.department && { id: employee.department.id, name: employee.department.name },
        role: employee.job_title.presence,
        account: account(access, user, opened[user&.id]),
        terms: {
          version: accepted&.fetch(:version),
          accepted_at: accepted&.fetch(:at)&.iso8601,
          current: accepted.present? && accepted[:version] == current_terms&.version
        },
        pay_statements: answer_payload(answers.dig(employee.id, "pay_statements")),
        w2gu: answer_payload(answers.dig(employee.id, "w2gu"))
      }
    end
  end

  def account(access, user, opened_at)
    status = @rollout.status_of(access)
    expired = %i[invited locked].include?(status) && access.invite_expires_at.present? && access.invite_expires_at <= @now
    status = :invite_expired if status == :invited && expired
    status = :deactivated if status == :active && user && !user.active?
    {
      status: status,
      label: ACCOUNT_LABELS.fetch(status),
      invite_sent_at: access && (access.last_invited_at || access.created_at).iso8601,
      invite_expires_at: (access.invite_expires_at&.iso8601 if access&.invited?),
      invite_expired: expired,
      signed_up_at: access&.activated_at&.iso8601,
      last_opened_at: opened_at&.iso8601,
      locked_until: (access.activation_locked_until&.iso8601 if status == :locked)
    }
  end

  def answer_payload(answer)
    { answer: answer[:answer], answered_at: answer[:answered_at]&.iso8601 }
  end

  # The terms version the employee agreed to most recently, across their links.
  def terms_by_employee(employee_ids)
    links = EmployeeAccountLink.where(company_id: @company.id, employee_id: employee_ids).pluck(:id, :employee_id).to_h
    return {} if links.empty?

    AuditLog.where(company_id: @company.id, record_type: EmployeeLinks::AUDIT_RECORD_TYPE, record_id: links.keys, action: TERMS_ACTIONS)
      .where("metadata ? 'terms_version'")
      .order(:created_at, :id)
      .pluck(:record_id, Arel.sql("metadata ->> 'terms_version'"), :created_at)
      .each_with_object({}) { |(link_id, version, at), result| result[links[link_id]] = { version: version, at: at } }
  end

  def last_opened(user_ids)
    return {} if user_ids.empty?

    AuditLog.where(company_id: @company.id, action: APP_OPEN_ACTION, user_id: user_ids).group(:user_id).maximum(:created_at)
  end

  def summary(rows)
    {
      total: rows.size,
      signed_up: rows.count { |row| row.dig(:account, :signed_up_at) },
      **FILTERS.index_with { |filter| rows.count { |row| matches?(row, filter) } }.symbolize_keys
    }
  end

  def narrow(rows, filter:, department_id:, role:, query:)
    rows = rows.select { |row| matches?(row, filter) } if FILTERS.include?(filter)
    rows = rows.select { |row| row.dig(:department, :id).to_s == department_id.to_s } if department_id.present?
    rows = rows.select { |row| row[:role] == role } if role.present?
    if query.present?
      needle = query.to_s.squish.downcase
      rows = rows.select { |row| row[:name].downcase.include?(needle) }
    end
    rows
  end

  def matches?(row, filter)
    answers = [ row.dig(:pay_statements, :answer), row.dig(:w2gu, :answer) ]
    case filter
    when "never_signed_in" then row.dig(:account, :signed_up_at).nil?
    when "invite_expired" then row.dig(:account, :invite_expired)
    when "terms_not_accepted" then !row.dig(:terms, :current)
    when "no_paperless_answer" then answers.include?(DeliveryConsents::Answers::NOT_ANSWERED)
    when "kept_paper" then answers.include?(DeliveryConsents::Answers::KEEP_PAPER)
    else false
    end
  end

  def export_row(row)
    account = row[:account]
    [
      row[:name], row.dig(:department, :name), row[:role], account[:label],
      day(account[:invite_sent_at]), day(account[:invite_expires_at]), day(account[:signed_up_at]), day(account[:last_opened_at]),
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
