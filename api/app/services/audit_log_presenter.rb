# frozen_string_literal: true

class AuditLogPresenter
  REPORT_FORMAT_SUFFIXES = %w[pdf csv xlsx ascii].freeze
  REPORT_NAMES = {
    "payroll_register" => "payroll register",
    "payroll_summary_by_employee" => "payroll summary by employee",
    "deductions_contributions" => "deductions and contributions report",
    "paycheck_history" => "paycheck history",
    "retirement_plans" => "retirement plans report",
    "installment_loans" => "installment loans report",
    "tax_summary" => "tax summary",
    "ytd_summary" => "year-to-date summary",
    "annual_payroll_summary" => "annual payroll summary",
    "employee_pay_history" => "employee pay history",
    "form_941_gu" => "Form 941 preparation report",
    "quarterly_compliance_packet" => "quarterly compliance packet",
    "quarterly_compliance_packet_swica" => "SWICA wage record",
    "w2_gu" => "W-2GU report",
    "form_1099_nec" => "1099-NEC report",
    "full_print_package" => "full payroll print package",
    "transmittal_log" => "transmittal log"
  }.freeze
  VERBS = {
    "view_as#started" => "viewed as",
    "companies#create" => "created",
    "client_operating_profile.update" => "updated the operating profile for",
    "test_workspace#create" => "created the test workspace",
    "companies#created" => "created",
    "employees#created" => "created the employee record for",
    "pay_periods#created" => "created the pay period",
    "authentication#signed_in" => "signed in",
    "authentication#mfa_required_denied" => "was denied payroll access because multi-factor authentication was required",
    "client_documents#create" => "uploaded",
    "admin_client_documents#create" => "uploaded",
    "client_documents#destroy" => "deleted",
    "admin_client_documents#destroy" => "deleted",
    "portal_documents#reviewed" => "reviewed",
    "portal_documents#opened" => "opened",
    "portal_documents#preview" => "previewed",
    "portal_documents#download" => "downloaded",
    "client_documents#archive" => "archived",
    "admin_client_documents#archive" => "archived",
    "admin_client_documents#unarchive" => "unarchived",
    "client_portal_threads#create" => "started conversation",
    "client_portal_threads#opened" => "opened conversation",
    "client_portal_threads#mark_read" => "marked read",
    "client_portal_threads#resolved" => "resolved conversation",
    "client_portal_threads#reopened" => "reopened conversation",
    "client_portal_threads#update" => "updated conversation",
    "client_portal_messages#create" => "sent a message in",
    "portal_file_requests#create" => "requested a file in",
    "portal_file_requests#respond" => "sent a requested file in",
    "portal_file_requests#accept" => "accepted a requested file in",
    "portal_file_requests#ask_again" => "asked again for a file in",
    "portal_file_requests#withdraw" => "withdrew a file request in",
    "payroll_submissions#create" => "sent payroll files for",
    "payroll_submission_periods#acknowledge" => "confirmed receipt of payroll files for",
    "payroll_submissions#open_import" => "opened payroll files in import review for",
    "payroll_submission_periods#import" => "imported payroll files for",
    "payroll_submission_periods#resolve_source" => "recorded a source disposition for",
    "payroll_submission_periods#start_review" => "started reviewing",
    "payroll_submission_periods#approve" => "approved the draft for",
    "payroll_submission_periods#request_changes" => "requested a change to the draft for",
    "payroll_submission_periods#mark_paid" => "marked paid",
    "payroll_submission_drafts#create" => "saved a staff-only draft for",
    "payroll_submission_drafts#post" => "posted a draft for review for",
    "notification_settings#update" => "updated email alert settings for",
    "portal_notification_recipients#update" => "updated the Cornerstone account team for",
    "employees#create" => "added",
    "employees#update" => "updated",
    "employees#confirm_same_person_email" => "confirmed a same-person login email for",
    "employees#clear_shared_email" => "cleared a shared or placeholder email for",
    "employee_contact_hygiene#mark_placeholder_email" => "marked a placeholder email",
    "employee_contact_hygiene#unmark_placeholder_email" => "removed a placeholder email",
    "employee_contact_hygiene#clear_shared_emails" => "cleared a shared or placeholder email for",
    "employee#compensation_changed" => "changed compensation for",
    "employees#destroy" => "terminated",
    "employees#reactivate" => "reactivated",
    "employee_notes#create" => "added a staff note for",
    "employee_notes#hide" => "hid a staff note for",
    "employee_notes#reveal" => "viewed a hidden staff note for",
    "client_employees#create" => "added",
    "client_employees#update" => "updated",
    "employee_change_requests#superseded" => "replaced a pending address request for",
    "users#created" => "created the user account for",
    "users#updated" => "updated the user account for",
    "users#activated" => "activated the user account for",
    "users#deactivated" => "deactivated the user account for",
    "users#deleted" => "deleted the user account for",
    "users#invitation_resent" => "resent an invitation to",
    "users#create" => "created the user account for",
    "users#update" => "updated the user account for",
    "users#deactivate" => "deactivated the user account for",
    "users#destroy" => "deleted the user account for",
    "company_assignments#bulk_update" => "updated client access for",
    "pay_periods#create" => "created the pay period",
    "pay_periods#run_payroll" => "calculated payroll for",
    "pay_periods#approve" => "approved payroll for",
    "pay_periods#unapprove" => "reopened payroll approval for",
    "pay_periods#commit" => "processed payroll for",
    "pay_periods#destroy" => "deleted the pay period",
    "pay_periods#update" => "updated the pay period",
    "pay_periods#generate_fit_check" => "generated the FIT check for",
    "pay_periods#void" => "voided payroll for",
    "pay_periods#correct_pay_date" => "corrected the pay date for",
    "checks#update_check_number" => "updated the check number for",
    "checks#check_number_updated" => "updated the check number for",
    "non_employee_checks#update" => "updated",
    "non_employee_checks#updated" => "updated",
    "check_print_runs#generated" => "generated a check print package for",
    "check_print_runs#confirmed" => "confirmed printed checks for",
    "correct_committed_pay_date" => "corrected the committed pay date for",
    "create_correction_run" => "created a correction run for",
    "void_pay_period" => "voided payroll for",
    "reopen_unpaid" => "reopened unpaid payroll for",
    "payroll_item#fit_override" => "changed final Guam income tax withholding for"
  }.freeze

  def self.preload_pay_period_subjects(logs)
    return load_pay_period_subjects(logs) if TenantScope.current

    TenantScope.as_system(reason: "Load audit subjects from already-authorized audit events") do
      load_pay_period_subjects(logs)
    end
  end

  def self.load_pay_period_subjects(logs)
    references = logs.filter_map { |log| pay_period_reference(log) }.uniq
    return {} if references.empty?

    company_ids = references.map(&:first).uniq
    pay_period_ids = references.map(&:last).uniq
    reference_set = references.index_with(true)

    PayPeriod.where(company_id: company_ids, id: pay_period_ids)
      .pluck(:company_id, :id, :start_date, :end_date)
      .each_with_object({}) do |(company_id, id, start_date, end_date), subjects|
        reference = [ company_id, id ]
        next unless reference_set.key?(reference)

        subjects[reference] = "#{start_date&.strftime('%b %-d, %Y')} – #{end_date&.strftime('%b %-d, %Y')}"
      end
  end

  # Older run rows stored only an employee ID. Names are read in one query,
  # each within the row's own client.
  def self.preload_employee_names(logs)
    return load_employee_names(logs) if TenantScope.current

    TenantScope.as_system(reason: "Load audit subjects from already-authorized audit events") do
      load_employee_names(logs)
    end
  end

  def self.load_employee_names(logs)
    references = logs.filter_map do |log|
      next unless PayRunActivityPhrase.handles?(log.action) && log.company_id.present?
      next if log.subject_name.present? || log.metadata&.dig("employee_name").present?

      employee_id = log.metadata&.dig("employee_id") || log.metadata&.dig("resolution", "employee_id")
      [ log.company_id, employee_id.to_i ] if employee_id.present?
    end.uniq
    return {} if references.empty?

    reference_set = references.index_with(true)
    Employee.where(company_id: references.map(&:first).uniq, id: references.map(&:last).uniq)
      .select(:id, :company_id, :first_name, :middle_name, :last_name)
      .each_with_object({}) do |employee, names|
        reference = [ employee.company_id, employee.id ]
        names[reference] = employee.full_name if reference_set.key?(reference)
      end
  end

  private_class_method :load_pay_period_subjects, :load_employee_names

  def self.pay_period_reference(log)
    pay_period_id = if %w[PayPeriod pay_period payperiod pay_periods].include?(log.record_type)
      log.record_id
    else
      log.metadata&.fetch("pay_period_id", nil)
    end
    return if pay_period_id.blank? || log.company_id.blank?

    [ log.company_id, pay_period_id.to_i ]
  end

  # run_context_id names the pay run being viewed, so its own actions can say
  # "this run"; elsewhere they name the run's dates.
  def initialize(log, pay_period_subjects: {}, run_context_id: nil, employee_names: nil)
    @log = log
    @pay_period_subjects = pay_period_subjects
    @run_context_id = run_context_id
    @employee_names = employee_names
  end

  def headline
    @headline ||= if log.action.in?(%w[authentication#signed_in authentication#mfa_required_denied])
      "#{actor_name} #{verb}"
    elsif (worker_headline = PayRunActivityPhrase.worker_headline(log))
      worker_headline
    elsif (phrase = pay_run_phrase)
      "#{actor_name} #{phrase}"
    elsif report_action?
      report_headline
    else
      [ actor_name, verb, subject ].compact_blank.join(" ")
    end
  end

  def summary
    context = log.company&.name.presence || log.organization&.name.presence
    @summary ||= context.blank? ? headline : "#{headline} · #{context}"
  end

  def subject
    @subject ||= report_action? ? report_subject : record_subject
  end

  private

  attr_reader :log

  def actor_name
    log.actor_name.presence || log.user&.name.presence || "System"
  end

  def verb
    VERBS[log.action] || fallback_verb
  end

  def fallback_verb
    action = log.action.to_s.split("#").last.to_s.tr("_", " ")
    action.presence || "performed an action on"
  end

  def fallback_subject
    type = log.record_type.to_s.sub(/^client_/, "").underscore.tr("_", " ").singularize
    return type if log.record_id.blank?

    "#{type} record"
  end

  def record_subject
    log.subject_name.presence || (log.metadata || {})["title"].presence || (log.metadata || {})["employee_name"].presence || (log.metadata || {})["subject"].presence || resolved_pay_period_subject || fallback_subject
  end

  def resolved_pay_period_subject
    return @resolved_pay_period_subject if defined?(@resolved_pay_period_subject)
    return unless pay_period_record?
    return if log.record_id.blank? || log.company_id.blank?

    reference = [ log.company_id, log.record_id.to_i ]
    return @resolved_pay_period_subject = @pay_period_subjects[reference] if @pay_period_subjects.key?(reference)

    pay_period = find_pay_period(log.record_id)
    @resolved_pay_period_subject = AuditRecordSnapshot.subject_name(pay_period)
  end

  def pay_period_record?
    %w[PayPeriod pay_period payperiod pay_periods].include?(log.record_type)
  end

  def pay_run_phrase
    return unless PayRunActivityPhrase.handles?(log.action)

    PayRunActivityPhrase.call(log, run_label: run_label, lookup_employee_name: method(:company_employee_name))
  end

  def run_label
    pay_period_id = self.class.pay_period_reference(log)&.last
    # Inside a run's feed, older rows without a run ID were found through it.
    return "this run" if @run_context_id.present? && (pay_period_id.blank? || pay_period_id == @run_context_id)
    return "the run" if pay_period_id.blank?

    subject = @pay_period_subjects[[ log.company_id, pay_period_id ]] ||
      AuditRecordSnapshot.subject_name(find_pay_period(pay_period_id))
    subject.present? ? "the #{subject} run" : "the run"
  end

  # Older rows stored only an employee ID; the name is read within the
  # row's own client.
  def company_employee_name(employee_id)
    return if log.company_id.blank?
    return @employee_names[[ log.company_id, employee_id.to_i ]] if @employee_names

    with_audit_subject_scope do
      Employee.select(:id, :first_name, :middle_name, :last_name).find_by(company_id: log.company_id, id: employee_id)&.full_name.presence
    end
  end

  def find_pay_period(id)
    with_audit_subject_scope do
      PayPeriod.select(:start_date, :end_date).find_by(id: id, company_id: log.company_id)
    end
  end

  def with_audit_subject_scope(&lookup)
    return yield if TenantScope.current || log.company_id.blank?

    TenantScope.with_company(log.company_id, &lookup)
  end

  def report_action?
    return false unless %w[document_access export].include?(log.event_category)

    normalized_record_type = log.record_type.to_s.sub(/^client_/, "")
    normalized_record_type == "reports" || log.action.to_s.match?(%r{\A(?:client_)?reports#})
  end

  def report_headline
    [ actor_name, report_verb, report_subject_with_period ].compact_blank.join(" ")
  end

  def report_subject
    [ display_report_name, report_period_subject ].compact_blank.join(" · ")
  end

  def report_subject_with_period
    base = "the #{report_name}"
    return base if report_period_subject.blank?

    "#{base} for #{report_period_subject}"
  end

  def report_verb
    access_type = log.metadata&.fetch("access_type", nil).to_s
    return "downloaded" if access_type == "download"
    return "viewed a preview of" if access_type == "preview"
    return "opened" if access_type == "view"

    action_name = log.action.to_s.split("#").last.to_s
    return "viewed a preview of" if action_name.include?("preview")
    return "downloaded" if REPORT_FORMAT_SUFFIXES.any? { |suffix| action_name.end_with?("_#{suffix}") }
    return "opened" if action_name.include?("print")

    "accessed"
  end

  def report_name
    metadata_key = log.metadata&.fetch("report_key", nil).to_s
    return REPORT_NAMES.fetch(metadata_key, metadata_key.tr("_", " ")) if metadata_key.present?

    metadata_name = log.metadata&.fetch("report_name", nil).to_s
    return metadata_name.downcase if metadata_name.present?

    action_name = log.action.to_s.split("#").last.to_s
    normalized = REPORT_FORMAT_SUFFIXES.reduce(action_name) { |name, suffix| name.sub(/_#{suffix}\z/, "") }
    normalized = normalized.sub(/_preview\z/, "").sub(/_print\z/, "")
    REPORT_NAMES.fetch(normalized, normalized.tr("_", " ").presence || "report")
  end

  def display_report_name
    return report_name if report_name.match?(/[A-Z]/)

    report_name.titleize
  end

  def report_period_subject
    log.subject_name.presence || log.metadata&.fetch("report_period_subject", nil).presence || resolved_report_pay_period_subject
  end

  def resolved_report_pay_period_subject
    return @resolved_report_pay_period_subject if defined?(@resolved_report_pay_period_subject)

    pay_period_id = log.metadata&.fetch("pay_period_id", nil)
    return if pay_period_id.blank? || log.company_id.blank?

    reference = [ log.company_id, pay_period_id.to_i ]
    return @resolved_report_pay_period_subject = @pay_period_subjects[reference] if @pay_period_subjects.key?(reference)

    pay_period = find_pay_period(pay_period_id)
    @resolved_report_pay_period_subject = AuditRecordSnapshot.subject_name(pay_period)
  end
end
